#!/usr/bin/env bash
# =============================================================================
# 18-mistral-ai-agent.sh — Mistral AI Agent Loop and CLI Wrapper Installation
# =============================================================================
# Installs the main Mistral AI OpenStack agent service and command-line interface.
# Provides interactive and single-command modes with conversation management,
# safety features, and systemd service integration for background operation.
#
# What it installs:
#   - Main AI agent loop with Mistral function calling
#   - Interactive CLI mode with conversation history
#   - Single command execution mode
#   - Systemd background service (mistral-ai-agent)
#   - CLI wrapper script (/usr/local/bin/mistral-os)
#   - Safety confirmations for destructive operations
#   - Dry-run mode for testing operations
#   - Transaction rollback integration
#   - Configuration template with security settings
#
# Components:
#   - agent.py (main AI agent with conversation management)
#   - /usr/local/bin/mistral-os (CLI wrapper)
#   - mistral-ai-agent.service (systemd service)
#   - /etc/mistral-openstack/agent.conf (configuration)
#
# Prerequisites:
#   - 13-mistral-ai-core.sh (core agent installation)
#   - 14-17 scripts (tool modules)
#   - MISTRAL_API_KEY environment variable
#   - OpenStack credentials (admin-openrc)
#
# Usage:
#   sudo bash 18-mistral-ai-agent.sh           # Install agent and CLI
#   sudo bash 18-mistral-ai-agent.sh --uninstall # Remove agent and CLI
#   mistral-os                                  # Interactive mode
#   mistral-os 'create 2 servers'              # Single command
#   systemctl start mistral-ai-agent           # Background service
#
# Re-run safe: Yes (service replacement approach)
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/mistral-openstack"
CONFIG_DIR="/etc/mistral-openstack"
LOG_DIR="/var/log/mistral-os"
SERVICE_USER="mistral"

# ── Uninstall Mode ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing Mistral AI agent and CLI..."
    
    # Stop and disable agent service
    systemctl stop mistral-ai-agent || true
    systemctl disable mistral-ai-agent || true
    rm -f /etc/systemd/system/mistral-ai-agent.service
    systemctl daemon-reload
    
    # Remove CLI wrapper
    rm -f /usr/local/bin/mistral-os
    
    # Remove agent modules
    rm -f "$INSTALL_DIR/agent.py"
    rm -f "$INSTALL_DIR/cli.py"
    
    # Remove any agent-related logs or cache
    find "$INSTALL_DIR" -name "*agent*" -type f -delete 2>/dev/null || true
    find "$LOG_DIR" -name "*agent*" -type f -delete 2>/dev/null || true
    
    echo "Mistral AI agent and CLI removed"
    exit 0
fi

# ── Functions ─────────────────────────────────────────────────────────────────

create_agent_module() {
    echo "Creating agent.py..."
    cat > "$INSTALL_DIR/agent.py" << 'EOF'
#!/usr/bin/env python3

import json
import logging
import os
import sys
import time
from typing import Dict, Any, List

from client import get_mistral_client
from rollback import BuildTransaction
from transaction import set_transaction
from tools import TOOLS, HANDLERS, DESTRUCTIVE_TOOLS

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    handlers=[
        logging.FileHandler('/var/log/mistral-os/agent.log'),
        logging.StreamHandler(sys.stdout)
    ]
)

log = logging.getLogger("mistral-os.agent")

class MistralOpenStackAgent:
    """
    AI-powered OpenStack automation agent using Mistral AI function calling.
    """
    
    def __init__(self, dry_run: bool = False):
        self.client = get_mistral_client()
        self.dry_run = dry_run
        self.conversation_history: List[Dict[str, Any]] = [{"role": "system", "content": "You are an OpenStack automation assistant with access to tools that directly execute operations on a live OpenStack Caracal (2024.1) deployment. When users request actions like 'create a load balancer', 'launch instances', 'create networks', or 'check quota', you MUST use your available tools to perform these operations immediately rather than providing instructions. Only provide manual instructions if the user specifically asks 'how do I...' or 'show me the steps to...'. For action requests: execute the tools, report the results, and confirm completion. Available services: Nova (compute), Neutron (networking), Cinder (block storage), Octavia (load balancing), Glance (images). Always use tools to get current data and perform requested operations."}]
    
    def process_request(self, user_message: str) -> str:
        """
        Process a user request using Mistral AI function calling.
        Returns the assistant's response.
        """
        log.info(f"Processing request: {user_message[:100]}...")
        
        # Add user message to conversation
        self.conversation_history.append({
            "role": "user",
            "content": user_message
        })
        
        try:
            # Create transaction for rollback support
            with BuildTransaction(dry_run=self.dry_run) as tx:
                set_transaction(tx)
                
                # Make API call with function calling
                response = self.client.chat.complete(
                    model="mistral-large-latest",
                    messages=self.conversation_history,
                    tools=TOOLS,
                    tool_choice="auto",
                    temperature=0.1,
                )
                
                assistant_message = response.choices[0].message
                tool_calls = assistant_message.tool_calls or []
                
                # Add assistant message to conversation
                self.conversation_history.append({
                    "role": "assistant",
                    "content": assistant_message.content or "",
                    "tool_calls": [tc.model_dump() for tc in tool_calls] if tool_calls else None
                })
                
                # Execute tool calls
                tool_results = []
                for tool_call in tool_calls:
                    func_name = tool_call.function.name
                    func_args = json.loads(tool_call.function.arguments)
                    
                    log.info(f"Executing tool: {func_name} with args: {func_args}")
                    
                    # Check if tool is destructive and requires confirmation
                    if func_name in DESTRUCTIVE_TOOLS and not self.dry_run:
                        print(f"\n[WARNING] About to execute destructive operation: {func_name}")
                        print(f"Arguments: {json.dumps(func_args, indent=2)}")
                        confirm = input("Proceed? (yes/no): ").strip().lower()
                        if confirm != "yes":
                            result = f"Operation {func_name} cancelled by user"
                            log.info(f"Destructive operation cancelled: {func_name}")
                        else:
                            result = self._execute_tool(func_name, func_args)
                    else:
                        result = self._execute_tool(func_name, func_args)
                    
                    tool_results.append({
                        "tool_call_id": tool_call.id,
                        "role": "tool",
                        "name": func_name,
                        "content": str(result)
                    })
                
                # Add tool results to conversation
                if tool_results:
                    self.conversation_history.extend(tool_results)
                    
                    # Get final response from assistant
                    final_response = self.client.chat.complete(
                        model="mistral-large-latest",
                        messages=self.conversation_history,
                        temperature=0.1,
                    )
                    
                    final_content = final_response.choices[0].message.content
                    self.conversation_history.append({
                        "role": "assistant", 
                        "content": final_content
                    })
                    
                    # Commit transaction if everything succeeded
                    tx.commit()
                    return final_content
                else:
                    # No tools called, just return assistant response
                    tx.commit()
                    return assistant_message.content or "No response generated"
                    
        except Exception as exc:
            log.error(f"Request processing failed: {exc}")
            return f"Error: {exc}"
    
    def _execute_tool(self, func_name: str, func_args: Dict[str, Any]) -> str:
        """Execute a tool function and return its result."""
        if func_name not in HANDLERS:
            return f"Unknown tool: {func_name}"
        
        try:
            handler = HANDLERS[func_name]
            if self.dry_run and func_name in DESTRUCTIVE_TOOLS:
                return f"[DRY-RUN] Would execute {func_name} with {func_args}"
            
            result = handler(**func_args)
            log.info(f"Tool {func_name} completed successfully")
            return result
            
        except Exception as exc:
            log.error(f"Tool {func_name} failed: {exc}")
            return f"Tool execution failed: {exc}"
    
    def clear_history(self):
        """Clear conversation history."""
        self.conversation_history = []
        log.info("Conversation history cleared")

def main():
    """Interactive CLI mode."""
    print("Mistral AI OpenStack Agent")
    print("Type 'help' for commands, 'exit' to quit\n")
    
    agent = MistralOpenStackAgent()
    
    while True:
        try:
            user_input = input("mistral-os> ").strip()
            
            if not user_input:
                continue
            elif user_input.lower() in ('exit', 'quit', 'q'):
                print("Goodbye!")
                break
            elif user_input.lower() == 'help':
                print("""
Available commands:
  help     - Show this help
  clear    - Clear conversation history
  dry-run  - Toggle dry-run mode
  exit     - Exit the agent
  
Or enter any natural language request for OpenStack operations.

Examples:
  "Create 3 web servers using m1.small flavour on the private network"
  "List all my instances and their status"
  "Create a load balancer for my web servers with health checks"
  "Check if I have enough quota for 10 more instances"
                """)
            elif user_input.lower() == 'clear':
                agent.clear_history()
                print("Conversation history cleared")
            elif user_input.lower() == 'dry-run':
                agent.dry_run = not agent.dry_run
                status = "enabled" if agent.dry_run else "disabled"
                print(f"Dry-run mode {status}")
            else:
                response = agent.process_request(user_input)
                print(f"\n{response}\n")
                
        except KeyboardInterrupt:
            print("\nGoodbye!")
            break
        except Exception as exc:
            print(f"Error: {exc}")

if __name__ == "__main__":
    main()
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/agent.py"
    chmod +x "$INSTALL_DIR/agent.py"
}

create_cli_wrapper() {
    echo "Creating CLI wrapper..."
    cat > /usr/local/bin/mistral-os << 'EOF'
#!/bin/bash

# Mistral AI OpenStack CLI Wrapper
# Provides command-line access to the Mistral AI OpenStack agent

INSTALL_DIR="/opt/mistral-openstack"
SERVICE_USER="mistral"

# Check if core installation exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: Mistral AI OpenStack not installed"
    echo "Please run installation scripts first"
    exit 1
fi

# Set up environment
export MISTRAL_API_KEY="${MISTRAL_API_KEY:-}"
export PYTHONPATH="$INSTALL_DIR:$PYTHONPATH"

# Source OpenStack credentials if available
if [[ -f "/root/admin-openrc" ]]; then
    source /root/admin-openrc
elif [[ -f "$HOME/admin-openrc" ]]; then
    source "$HOME/admin-openrc"
fi

# Check for required environment variables
if [[ -z "$MISTRAL_API_KEY" ]]; then
    echo "Error: MISTRAL_API_KEY environment variable not set"
    echo "Export your Mistral API key: export MISTRAL_API_KEY='your-key-here'"
    exit 1
fi

# Execute with proper user context
cd "$INSTALL_DIR"

if [[ "$#" -eq 0 ]]; then
    # Interactive mode
    exec sudo -u "$SERVICE_USER" -E "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/agent.py"
else
    # Single command mode
    command="$*"
    exec sudo -u "$SERVICE_USER" -E "$INSTALL_DIR/venv/bin/python" -c "
from agent import MistralOpenStackAgent
agent = MistralOpenStackAgent()
response = agent.process_request('$command')
print(response)
"
fi
EOF
    chmod +x /usr/local/bin/mistral-os
}

create_systemd_service() {
    echo "Creating systemd service..."
    cat > /etc/systemd/system/mistral-ai-agent.service << EOF
[Unit]
Description=Mistral AI OpenStack Agent
After=network.target
Requires=redis-server.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=PYTHONPATH=$INSTALL_DIR
Environment=MISTRAL_API_KEY=${MISTRAL_API_KEY:-your-mistral-api-key-here}
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mistral-ai-agent

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$LOG_DIR $INSTALL_DIR
ProtectHome=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

create_configuration_template() {
    echo "Creating configuration template..."
    cat > "$CONFIG_DIR/agent.conf" << 'EOF'
# Mistral AI OpenStack Agent Configuration

# API Configuration
MISTRAL_API_KEY=your-mistral-api-key-here
MISTRAL_MODEL=mistral-large-latest

# OpenStack Configuration (optional - can use environment variables instead)
# OS_AUTH_URL=http://127.0.0.1/identity
# OS_PROJECT_NAME=admin
# OS_USERNAME=admin
# OS_PASSWORD=changeit
# OS_USER_DOMAIN_NAME=Default
# OS_PROJECT_DOMAIN_NAME=Default
# OS_IDENTITY_API_VERSION=3

# Agent Settings
DEFAULT_DRY_RUN=false
LOG_LEVEL=INFO
MAX_CONVERSATION_HISTORY=50

# Safety Settings
REQUIRE_CONFIRMATION_FOR_DESTRUCTIVE_OPS=true
DESTRUCTIVE_OPS_TIMEOUT_SECONDS=30
EOF
    chown root:root "$CONFIG_DIR/agent.conf"
    chmod 644 "$CONFIG_DIR/agent.conf"
}

# ── Main Installation ────────────────────────────────────────────────────────

echo "Installing Mistral AI Agent Loop and CLI..."

# Check if core installation exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: Core installation not found at $INSTALL_DIR"
    echo "Please run 13-mistral-ai-core.sh first"
    exit 1
fi

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Create agent and CLI components
create_agent_module
create_cli_wrapper
create_systemd_service
create_configuration_template

echo ""
echo "✓ Mistral AI Agent Loop and CLI installed"
echo ""
echo "Setup required:"
echo "  1. Set your Mistral API key:"
echo "     export MISTRAL_API_KEY='your-key-here'"
echo "  2. Update $CONFIG_DIR/agent.conf with your API key"
echo "  3. Source OpenStack credentials (admin-openrc)"
echo ""
echo "Usage:"
echo "  mistral-os                    # Interactive mode"
echo "  mistral-os 'create 2 servers' # Single command"
echo "  systemctl start mistral-ai-agent # Background service"
echo ""
echo "Examples:"
echo "  mistral-os 'list my instances'"
echo "  mistral-os 'create load balancer for web servers'"
echo "  mistral-os 'check quota headroom for 5 instances'"
echo ""
echo "Next: Run 19-mistral-ai-horizon.sh for dashboard integration"