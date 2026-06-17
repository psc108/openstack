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
        self.conversation_history: List[Dict[str, Any]] = [{"role": "system", "content": "You are an OpenStack automation assistant. CRITICAL: When users say 'create', 'launch', 'build', 'deploy', 'delete', 'remove' or similar action verbs, you MUST call the appropriate tool function immediately. DO NOT provide step-by-step instructions. DO NOT explain how to do it manually. IMMEDIATELY use your available tools: create_load_balancer, create_instance, delete_instance, list_instances, list_security_groups, etc. Example: User says 'create a load balancer' -> you MUST call create_load_balancer tool right now. User says 'launch 2 instances' -> you MUST call create_instance tool right now. Only provide manual instructions if user specifically asks 'how do I' or 'show me steps'. For action requests: call tools immediately, report results."}]
    
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
                
                # Make API call with function calling (0.4.2 API)
                response = self.client.chat(
                    model="mistral-large-latest",
                    messages=self.conversation_history,
                    tools=TOOLS,
                    tool_choice="any",
                    temperature=0.1,
                )
                
                assistant_message = response.choices[0].message
                tool_calls = assistant_message.tool_calls or []
                
                # Add assistant message to conversation
                self.conversation_history.append({
                    "role": "assistant",
                    "content": assistant_message.content or "",
                    "tool_calls": [tc.dict() for tc in tool_calls] if tool_calls else None
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
                    final_response = self.client.chat(
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
    import argparse
    
    parser = argparse.ArgumentParser(description='Mistral AI OpenStack Agent')
    parser.add_argument('--dry-run', action='store_true', help='Enable dry-run mode')
    parser.add_argument('--single', type=str, help='Process single command and exit')
    args = parser.parse_args()
    
    agent = MistralOpenStackAgent(dry_run=args.dry_run)
    
    if args.single:
        # Single command mode for API calls
        response = agent.process_request(args.single)
        print(response)
        return
    
    # Interactive CLI mode
    print("Mistral AI OpenStack Agent")
    print("Type 'help' for commands, 'exit' to quit\n")
    
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
