#!/usr/bin/env bash
# =============================================================================
# 19-mistral-ai-horizon.sh — Mistral AI Horizon Dashboard Panel Installation
# =============================================================================
# Installs Horizon dashboard integration for AI-powered OpenStack management.
# Creates a complete web-based chat interface with real-time quota monitoring,
# tool discovery, and interactive AI assistant functionality within Horizon.
#
# What it installs:
#   - Horizon dashboard panel (Mistral AI tab)
#   - Interactive chat interface with message history
#   - Real-time quota monitoring with visual progress bars
#   - Available tools overview with capability descriptions
#   - Dry-run mode toggle for safe operation testing
#   - AJAX-based API integration with proper Django views
#   - Responsive UI with modern chat styling
#   - Safety warnings for destructive operations
#
# Components:
#   - /openstack_dashboard/dashboards/mistral_ai/ (panel structure)
#   - horizon_api.py (Django API integration)
#   - Chat interface template with JavaScript
#   - REST endpoints for chat, tools, and quota APIs
#   - URL routing and view integration
#
# Prerequisites:
#   - 13-mistral-ai-core.sh (core agent installation)
#   - 14-17 scripts (tool modules)
#   - 08-horizon.sh (Horizon dashboard)
#   - MISTRAL_API_KEY available to Horizon process
#
# Usage:
#   sudo bash 19-mistral-ai-horizon.sh           # Install dashboard panel
#   sudo bash 19-mistral-ai-horizon.sh --uninstall # Remove dashboard panel
#
# Access: Horizon → Mistral AI → AI Assistant
#
# Post-install: Restart Apache, navigate to dashboard
#
# Re-run safe: Yes (panel replacement approach)
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

HORIZON_DIR="/usr/lib/python3/dist-packages/openstack_dashboard"
HORIZON_SETTINGS="/etc/openstack-dashboard/local_settings.py"
HORIZON_SHARE_DIR="/usr/share/openstack-dashboard"
INSTALL_DIR="/opt/mistral-openstack"
SERVICE_USER="mistral"

# ── Verify Mode ──────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--verify" ]]; then
    echo "Verifying Mistral AI Horizon integration..."
    
    echo ">>> Checking core installation:"
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "  ✓ Core installation found at $INSTALL_DIR"
    else
        echo "  ✗ Core installation missing at $INSTALL_DIR"
    fi
    
    echo ">>> Checking Horizon installation:"
    if [[ -d "$HORIZON_DIR" ]]; then
        echo "  ✓ Horizon found at $HORIZON_DIR"
    else
        echo "  ✗ Horizon missing at $HORIZON_DIR"
    fi
    
    echo ">>> Checking dashboard panel:"
    if [[ -d "$HORIZON_DIR/dashboards/mistral_ai" ]]; then
        echo "  ✓ Dashboard panel installed"
    else
        echo "  ✗ Dashboard panel missing"
    fi
    
    echo ">>> Checking enabled file:"
    if [[ -f "$HORIZON_DIR/enabled/_90_mistral_ai.py" ]]; then
        echo "  ✓ Enabled file present"
    else
        echo "  ✗ Enabled file missing"
    fi
    
    echo ">>> Checking horizon_api module:"
    if [[ -f "$INSTALL_DIR/horizon_api.py" ]]; then
        echo "  ✓ horizon_api.py present"
        # Test Python import
        cd "$INSTALL_DIR"
        if python3 -c "import horizon_api" 2>/dev/null; then
            echo "  ✓ horizon_api module imports successfully"
        else
            echo "  ⚠ horizon_api module has import issues"
        fi
    else
        echo "  ✗ horizon_api.py missing"
    fi
    
    echo ">>> Apache status:"
    systemctl is-active apache2 || echo "  ✗ Apache not running"
    
    echo ">>> Recent Apache errors (last 5 lines):"
    tail -5 /var/log/apache2/error.log 2>/dev/null || echo "  Cannot read Apache error log"
    
    exit 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing Mistral AI Horizon panel..."
    
    # Remove dashboard panel
    rm -rf "$HORIZON_DIR/dashboards/mistral_ai"
    
    # Remove static files
    rm -rf "$HORIZON_SHARE_DIR/static/mistral_ai"
    
    # Remove enabled file
    rm -f "$HORIZON_DIR/enabled/_90_mistral_ai.py"
    
    # Remove API module
    rm -f "$INSTALL_DIR/horizon_api.py"
    
    # Restart Apache to reload Horizon
    systemctl restart apache2 || true
    
    echo "Mistral AI Horizon panel removed"
    exit 0
fi

# ── Functions ─────────────────────────────────────────────────────────────────

create_horizon_api() {
    echo "Creating Horizon API module..."
    cat > "$INSTALL_DIR/horizon_api.py" << 'EOF'
"""
Horizon API integration for Mistral AI OpenStack agent.
Provides Django-compatible views and utilities.
"""

import json
import logging
import threading
from typing import Dict, Any, Optional

from django.http import JsonResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods
from django.utils.decorators import method_decorator
from django.views import View

# Import agent components
import sys
import os
sys.path.insert(0, '/opt/mistral-openstack')

from agent import MistralOpenStackAgent
from os_client import set_request_conn
import openstack

log = logging.getLogger("mistral-os.horizon")

class MistralAIView(View):
    """Base view for Mistral AI dashboard interactions."""
    
    @method_decorator(csrf_exempt)
    def dispatch(self, request, *args, **kwargs):
        # Set up OpenStack connection from request context
        try:
            conn = openstack.connect(
                auth_url=request.session.get('region_endpoint'),
                username=request.user.username,
                password=None,  # Use token-based auth
                token=request.session.get('token', {}).get('id'),
                project_id=request.session.get('token', {}).get('project', {}).get('id'),
                user_domain_name='Default',
                project_domain_name='Default',
            )
            set_request_conn(conn)
        except Exception as exc:
            log.warning(f"Failed to set request connection: {exc}")
        
        return super().dispatch(request, *args, **kwargs)

@method_decorator(csrf_exempt, name='dispatch')
class ChatView(MistralAIView):
    """Handle chat interactions with the Mistral AI agent."""
    
    def post(self, request):
        try:
            data = json.loads(request.body)
            user_message = data.get('message', '').strip()
            dry_run = data.get('dry_run', False)
            api_key = data.get('api_key', '').strip()
            
            if not user_message:
                return JsonResponse({'error': 'Message is required'}, status=400)
            
            if not api_key:
                return JsonResponse({'error': 'Mistral AI API key is required'}, status=400)
            
            # Set API key for this request
            import os
            os.environ['MISTRAL_API_KEY'] = api_key
            
            # Create agent instance
            agent = MistralOpenStackAgent(dry_run=dry_run)
            
            # Process the request
            response = agent.process_request(user_message)
            
            return JsonResponse({
                'response': response,
                'dry_run': dry_run,
                'timestamp': None  # Could add timestamp if needed
            })
            
        except Exception as exc:
            log.error(f"Chat request failed: {exc}")
            return JsonResponse({'error': str(exc)}, status=500)

@method_decorator(csrf_exempt, name='dispatch')
class ToolsView(MistralAIView):
    """Provide information about available tools."""
    
    def get(self, request):
        try:
            from tools import TOOLS, DESTRUCTIVE_TOOLS
            
            tools_info = []
            for tool in TOOLS:
                func_info = tool['function']
                tools_info.append({
                    'name': func_info['name'],
                    'description': func_info['description'],
                    'destructive': func_info['name'] in DESTRUCTIVE_TOOLS,
                    'parameters': func_info.get('parameters', {}),
                })
            
            return JsonResponse({
                'tools': sorted(tools_info, key=lambda x: x['name']),
                'total_count': len(tools_info),
            })
            
        except Exception as exc:
            log.error(f"Tools request failed: {exc}")
            return JsonResponse({'error': str(exc)}, status=500)

@method_decorator(csrf_exempt, name='dispatch') 
class QuotaView(MistralAIView):
    """Get quota information for the current project."""
    
    def get(self, request):
        try:
            from tools.quota import get_quota_details
            
            # Execute the quota tool directly
            quota_json = get_quota_details()
            quota_data = json.loads(quota_json)
            
            return JsonResponse(quota_data)
            
        except Exception as exc:
            log.error(f"Quota request failed: {exc}")
            return JsonResponse({'error': str(exc)}, status=500)

@method_decorator(csrf_exempt, name='dispatch')
class TestApiKeyView(MistralAIView):
    """Test if a Mistral AI API key is valid."""
    
    def post(self, request):
        try:
            data = json.loads(request.body)
            api_key = data.get('api_key', '').strip()
            
            if not api_key:
                return JsonResponse({'valid': False, 'error': 'API key is required'}, status=400)
            
            # Basic API key format validation
            if len(api_key) < 10:
                return JsonResponse({'valid': False, 'error': 'API key appears to be too short'}, status=400)
            
            if not api_key.strip():
                return JsonResponse({'valid': False, 'error': 'API key cannot be empty or whitespace'}, status=400)
            
            # Test with curl command - simpler and more reliable
            import subprocess
            
            curl_command = [
                'curl', '-s', '-w', '%{http_code}',
                '-H', 'Content-Type: application/json',
                '-H', f'Authorization: Bearer {api_key}',
                '-d', '{"model":"mistral-small","messages":[{"role":"user","content":"test"}],"max_tokens":5}',
                '--max-time', '15',
                'https://api.mistral.ai/v1/chat/completions'
            ]
            
            try:
                result = subprocess.run(curl_command, capture_output=True, text=True, timeout=20)
                
                # Get HTTP status code from output
                if result.stdout:
                    # curl -w '%{http_code}' appends the status code to stdout
                    lines = result.stdout.strip().split('\n')
                    if lines:
                        # Status code should be in the last line or part of response
                        status_code = lines[-1] if lines[-1].isdigit() else '000'
                        
                        if status_code == '200':
                            return JsonResponse({
                                'valid': True,
                                'message': 'API key is valid and working'
                            })
                        elif status_code == '401':
                            return JsonResponse({
                                'valid': False,
                                'error': 'Invalid API key - please check your Mistral AI API key'
                            })
                        elif status_code == '429':
                            return JsonResponse({
                                'valid': False,
                                'error': 'Rate limit exceeded - try again later'
                            })
                        elif status_code.startswith('5'):
                            return JsonResponse({
                                'valid': False,
                                'error': 'Mistral AI service temporarily unavailable'
                            })
                        else:
                            return JsonResponse({
                                'valid': False,
                                'error': f'API request failed (HTTP {status_code})'
                            })
                
                # If we get here, something went wrong
                return JsonResponse({
                    'valid': False,
                    'error': 'No response from API - check internet connection'
                })
                    
            except subprocess.TimeoutExpired:
                return JsonResponse({
                    'valid': False,
                    'error': 'Request timeout - check internet connection'
                })
            except Exception as e:
                return JsonResponse({
                    'valid': False,
                    'error': f'Connection failed: {str(e)}'
                })
            
        except Exception as exc:
            log.error(f"API key test failed: {exc}")
            return JsonResponse({'valid': False, 'error': str(exc)}, status=500)
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/horizon_api.py"
}

create_dashboard_panel() {
    echo "Creating Horizon dashboard panel..."
    
    # Create panel directory
    mkdir -p "$HORIZON_DIR/dashboards/mistral_ai"
    
    # Panel __init__.py
    cat > "$HORIZON_DIR/dashboards/mistral_ai/__init__.py" << 'EOF'
EOF
    
    # Dashboard definition
    cat > "$HORIZON_DIR/dashboards/mistral_ai/dashboard.py" << 'EOF'
from django.utils.translation import gettext_lazy as _
import horizon

class MistralAI(horizon.Dashboard):
    name = _("Mistral AI")
    slug = "mistral_ai"
    panels = ('chat',)
    default_panel = 'chat'
    roles = ('admin', 'member')

horizon.register(MistralAI)
EOF
    
    # Panel directory
    mkdir -p "$HORIZON_DIR/dashboards/mistral_ai/chat"
    
    # Panel __init__.py
    cat > "$HORIZON_DIR/dashboards/mistral_ai/chat/__init__.py" << 'EOF'
EOF
    
    # Panel definition
    cat > "$HORIZON_DIR/dashboards/mistral_ai/chat/panel.py" << 'EOF'
from django.utils.translation import gettext_lazy as _
import horizon
from openstack_dashboard.dashboards.mistral_ai import dashboard

class Chat(horizon.Panel):
    name = _("AI Assistant")
    slug = "chat"

dashboard.MistralAI.register(Chat)
EOF
    
    # Views
    cat > "$HORIZON_DIR/dashboards/mistral_ai/chat/views.py" << 'EOF'
from django.views import generic
from django.utils.translation import gettext_lazy as _

class IndexView(generic.TemplateView):
    template_name = 'mistral_ai/chat/index.html'
    page_title = _("AI Assistant")
    
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context['page_title'] = self.page_title
        return context
EOF
    
    # URLs
    cat > "$HORIZON_DIR/dashboards/mistral_ai/chat/urls.py" << 'EOF'
from django.urls import re_path
from openstack_dashboard.dashboards.mistral_ai.chat import views

urlpatterns = [
    re_path(r'^$', views.IndexView.as_view(), name='index'),
]
EOF
}

create_templates() {
    echo "Creating dashboard templates..."
    
    # Create template directory at dashboard level (not panel level)
    mkdir -p "$HORIZON_DIR/dashboards/mistral_ai/templates/mistral_ai/chat"
    
    # Main chat interface template
    cat > "$HORIZON_DIR/dashboards/mistral_ai/templates/mistral_ai/chat/index.html" << 'EOF'
{% extends 'base.html' %}
{% load i18n %}
{% load static %}

{% block title %}{% trans "AI Assistant" %}{% endblock %}

{% block page_header %}
  {% include "horizon/common/_domain_page_header.html" with title=_("AI Assistant") %}
{% endblock page_header %}

{% block main %}
<div class="row">
  <div class="col-md-12">
    <div class="panel panel-default">
      <div class="panel-heading">
        <h3 class="panel-title">{% trans "Mistral AI OpenStack Assistant" %}</h3>
      </div>
      <div class="panel-body">
        
        <!-- Chat Interface -->
        <div id="chat-container" class="chat-container">
          
          <!-- API Key Configuration Section -->
          <div class="panel panel-warning" id="api-key-panel">
            <div class="panel-heading">
              <h4 class="panel-title">
                <span class="glyphicon glyphicon-cog"></span>
                Mistral AI Configuration
              </h4>
            </div>
            <div class="panel-body">
              <div class="row">
                <div class="col-md-8">
                  <div class="input-group">
                    <span class="input-group-addon">API Key</span>
                    <input type="password" id="api-key-input" class="form-control" 
                           placeholder="Enter your Mistral AI API key..." maxlength="200">
                    <div class="input-group-btn">
                      <button id="save-key-btn" class="btn btn-success">Save & Test</button>
                      <button id="clear-key-btn" class="btn btn-default">Clear</button>
                    </div>
                  </div>
                  <div id="key-status" class="help-block"></div>
                </div>
                <div class="col-md-4">
                  <div class="checkbox">
                    <label>
                      <input type="checkbox" id="show-key-toggle"> Show API key
                    </label>
                  </div>
                  <small class="text-muted">
                    Your API key is stored securely in your browser session and never logged.
                  </small>
                </div>
              </div>
            </div>
          </div>
          
          <div id="chat-messages" class="chat-messages">
            <div class="message assistant">
              <strong>AI Assistant:</strong> 
              Welcome! Please configure your Mistral AI API key above to start using the AI assistant.
            </div>
          </div>
          
            <div class="chat-input-container">
            <div class="input-group">
              <input type="text" id="chat-input" class="form-control" 
                     placeholder="Ask me about your OpenStack infrastructure..." 
                     maxlength="1000" disabled>
              <div class="input-group-btn">
                <button id="send-btn" class="btn btn-primary" disabled>Send</button>
                <button id="clear-btn" class="btn btn-default">Clear</button>
              </div>
            </div>
            <div class="chat-options">
              <label class="checkbox-inline">
                <input type="checkbox" id="dry-run-toggle"> Dry Run Mode
              </label>
              <span class="help-text">
                Dry run mode simulates operations without making changes
              </span>
            </div>
          </div>
        </div>

        <!-- Tools Information -->
        <div class="panel-group" id="accordion">
          <div class="panel panel-default">
            <div class="panel-heading">
              <h4 class="panel-title">
                <a data-toggle="collapse" data-parent="#accordion" href="#tools-collapse">
                  Available Tools & Capabilities
                </a>
              </h4>
            </div>
            <div id="tools-collapse" class="panel-collapse collapse">
              <div class="panel-body">
                <div id="tools-list">Loading...</div>
              </div>
            </div>
          </div>
        </div>

        <!-- Quota Status -->
        <div class="panel panel-info">
          <div class="panel-heading">
            <h4 class="panel-title">Current Quota Status</h4>
          </div>
          <div class="panel-body">
            <div id="quota-status">Loading...</div>
          </div>
        </div>

      </div>
    </div>
  </div>
</div>

<style>
.chat-container {
  max-width: 100%;
  margin: 0 auto;
}

.chat-messages {
  height: 400px;
  overflow-y: auto;
  border: 1px solid #ddd;
  padding: 15px;
  margin-bottom: 15px;
  background-color: #f9f9f9;
}

.message {
  margin-bottom: 15px;
  padding: 10px;
  border-radius: 5px;
}

.message.user {
  background-color: #e3f2fd;
  margin-left: 20px;
}

.message.assistant {
  background-color: #f3e5f5;
  margin-right: 20px;
}

.message.error {
  background-color: #ffebee;
  border-left: 4px solid #f44336;
}

.chat-input-container {
  margin-top: 15px;
}

.chat-options {
  margin-top: 10px;
  padding: 5px 0;
}

.help-text {
  font-size: 0.9em;
  color: #666;
  margin-left: 10px;
}

.loading {
  text-align: center;
  color: #666;
  font-style: italic;
}

.tools-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 15px;
  margin-top: 10px;
}

.tool-item {
  border: 1px solid #ddd;
  padding: 10px;
  border-radius: 4px;
}

.tool-item.destructive {
  border-left: 4px solid #ff9800;
}

.quota-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 15px;
}

.quota-item {
  text-align: center;
  padding: 15px;
  background-color: #f5f5f5;
  border-radius: 4px;
}

.quota-bar {
  width: 100%;
  height: 8px;
  background-color: #ddd;
  border-radius: 4px;
  margin: 5px 0;
}

.quota-bar-fill {
  height: 100%;
  border-radius: 4px;
  transition: width 0.3s ease;
}

.quota-bar-fill.low { background-color: #4caf50; }
.quota-bar-fill.medium { background-color: #ff9800; }
.quota-bar-fill.high { background-color: #f44336; }
</style>

<script>
$(document).ready(function() {
    const chatMessages = $('#chat-messages');
    const chatInput = $('#chat-input');
    const sendBtn = $('#send-btn');
    const clearBtn = $('#clear-btn');
    const dryRunToggle = $('#dry-run-toggle');
    
    // API Key management
    const apiKeyInput = $('#api-key-input');
    const saveKeyBtn = $('#save-key-btn');
    const clearKeyBtn = $('#clear-key-btn');
    const showKeyToggle = $('#show-key-toggle');
    const keyStatus = $('#key-status');
    const apiKeyPanel = $('#api-key-panel');
    
    let currentApiKey = null;

    // Load saved API key from sessionStorage
    function loadSavedApiKey() {
        const savedKey = sessionStorage.getItem('mistral_api_key');
        if (savedKey) {
            currentApiKey = savedKey;
            apiKeyInput.val(savedKey);
            keyStatus.html('<span class="text-success">✓ API key loaded from session</span>');
            enableChat();
            // Hide the API key panel once configured
            apiKeyPanel.removeClass('panel-warning').addClass('panel-success');
            apiKeyPanel.find('.panel-body').slideUp();
        }
    }
    
    // Save API key and test it
    function saveAndTestApiKey() {
        const apiKey = apiKeyInput.val().trim();
        if (!apiKey) {
            keyStatus.html('<span class="text-danger">Please enter an API key</span>');
            return;
        }
        
        keyStatus.html('<span class="text-info">Testing API key...</span>');
        saveKeyBtn.prop('disabled', true);
        
        // Test the API key by making a simple request
        $.ajax({
            url: '{% url "horizon:mistral_ai:chat:test_api_key" %}',
            method: 'POST',
            data: JSON.stringify({ api_key: apiKey }),
            contentType: 'application/json',
            success: function(response) {
                if (response.valid) {
                    currentApiKey = apiKey;
                    sessionStorage.setItem('mistral_api_key', apiKey);
                    keyStatus.html('<span class="text-success">✓ API key valid and saved</span>');
                    enableChat();
                    // Minimize the API key panel
                    apiKeyPanel.removeClass('panel-warning').addClass('panel-success');
                    apiKeyPanel.find('.panel-body').slideUp();
                    
                    // Update welcome message
                    addMessage('assistant', 'API key configured successfully! How can I help you with your OpenStack infrastructure?');
                } else {
                    keyStatus.html('<span class="text-danger">✗ Invalid API key: ' + (response.error || 'Unknown error') + '</span>');
                    currentApiKey = null;
                }
            },
            error: function(xhr) {
                const error = xhr.responseJSON?.error || 'Connection failed';
                keyStatus.html('<span class="text-danger">✗ Test failed: ' + error + '</span>');
                currentApiKey = null;
            },
            complete: function() {
                saveKeyBtn.prop('disabled', false);
            }
        });
    }
    
    // Clear API key
    function clearApiKey() {
        currentApiKey = null;
        apiKeyInput.val('');
        sessionStorage.removeItem('mistral_api_key');
        keyStatus.html('<span class="text-info">API key cleared</span>');
        disableChat();
        apiKeyPanel.removeClass('panel-success').addClass('panel-warning');
        apiKeyPanel.find('.panel-body').slideDown();
        
        // Clear chat and show setup message
        chatMessages.html(`
            <div class="message assistant">
                <strong>AI Assistant:</strong> 
                Welcome! Please configure your Mistral AI API key above to start using the AI assistant.
            </div>
        `);
    }
    
    // Enable chat interface
    function enableChat() {
        chatInput.prop('disabled', false);
        sendBtn.prop('disabled', false);
        chatInput.attr('placeholder', 'Ask me about your OpenStack infrastructure...');
    }
    
    // Disable chat interface
    function disableChat() {
        chatInput.prop('disabled', true);
        sendBtn.prop('disabled', true);
        chatInput.attr('placeholder', 'Please configure API key first...');
    }
    
    // Toggle API key visibility
    showKeyToggle.change(function() {
        apiKeyInput.attr('type', this.checked ? 'text' : 'password');
    });
    
    // API Key event handlers
    saveKeyBtn.click(saveAndTestApiKey);
    clearKeyBtn.click(clearApiKey);
    apiKeyInput.keypress(function(e) {
        if (e.which === 13) saveAndTestApiKey();
    });
    
    // Click panel header to toggle configuration
    apiKeyPanel.find('.panel-heading').click(function() {
        apiKeyPanel.find('.panel-body').slideToggle();
    }).css('cursor', 'pointer');

    // Load tools and quota on page load
    loadTools();
    loadQuota();
    loadSavedApiKey();

    // Send message (now includes API key)
    function sendMessage() {
        if (!currentApiKey) {
            addMessage('error', 'Please configure your Mistral AI API key first.');
            return;
        }
        
        const message = chatInput.val().trim();
        if (!message) return;

        // Add user message to chat
        addMessage('user', message);
        chatInput.val('');
        sendBtn.prop('disabled', true);

        // Show loading
        const loadingId = addMessage('assistant', 'Thinking...');

        // Send to API with API key
        $.ajax({
            url: '{% url "horizon:mistral_ai:chat:chat_api" %}',
            method: 'POST',
            data: JSON.stringify({
                message: message,
                dry_run: dryRunToggle.is(':checked'),
                api_key: currentApiKey
            }),
            contentType: 'application/json',
            success: function(response) {
                removeMessage(loadingId);
                addMessage('assistant', response.response);
                // Refresh quota after operations
                loadQuota();
            },
            error: function(xhr) {
                removeMessage(loadingId);
                const error = xhr.responseJSON?.error || 'Request failed';
                if (error.includes('API key') || error.includes('authentication')) {
                    addMessage('error', 'API key issue: ' + error + '. Please check your API key configuration.');
                    clearApiKey();
                } else {
                    addMessage('error', 'Error: ' + error);
                }
            },
            complete: function() {
                sendBtn.prop('disabled', false);
                if (currentApiKey) chatInput.focus();
            }
        });
    }

    // Add message to chat
    function addMessage(type, content) {
        const messageId = 'msg-' + Date.now();
        const messageHtml = `
            <div class="message ${type}" id="${messageId}">
                <strong>${type === 'user' ? 'You' : (type === 'error' ? 'Error' : 'AI Assistant')}:</strong>
                <span>${content}</span>
            </div>
        `;
        chatMessages.append(messageHtml);
        chatMessages.scrollTop(chatMessages[0].scrollHeight);
        return messageId;
    }

    // Remove message
    function removeMessage(messageId) {
        $('#' + messageId).remove();
    }

    // Load available tools
    function loadTools() {
        $.get('{% url "horizon:mistral_ai:chat:tools_api" %}')
            .done(function(data) {
                displayTools(data.tools);
            })
            .fail(function() {
                $('#tools-list').html('<em>Failed to load tools</em>');
            });
    }

    // Display tools
    function displayTools(tools) {
        let html = `<p><strong>${tools.length}</strong> AI-powered tools available:</p><div class="tools-grid">`;
        tools.forEach(function(tool) {
            const destructiveClass = tool.destructive ? 'destructive' : '';
            html += `
                <div class="tool-item ${destructiveClass}">
                    <h5>${tool.name} ${tool.destructive ? '⚠️' : ''}</h5>
                    <p>${tool.description}</p>
                </div>
            `;
        });
        html += '</div>';
        $('#tools-list').html(html);
    }

    // Load quota status
    function loadQuota() {
        $.get('{% url "horizon:mistral_ai:chat:quota_api" %}')
            .done(function(data) {
                displayQuota(data);
            })
            .fail(function() {
                $('#quota-status').html('<em>Failed to load quota</em>');
            });
    }

    // Display quota
    function displayQuota(quota) {
        let html = '<div class="quota-grid">';
        
        // Compute quota
        if (quota.compute) {
            html += renderQuotaItem('Instances', quota.compute.instances);
            html += renderQuotaItem('vCPUs', quota.compute.vcpus);
            html += renderQuotaItem('RAM (MB)', quota.compute.ram_mb);
        }
        
        // Network quota
        if (quota.network) {
            html += renderQuotaItem('Floating IPs', quota.network.floating_ips);
            html += renderQuotaItem('Security Groups', quota.network.security_groups);
        }
        
        html += '</div>';
        $('#quota-status').html(html);
    }

    // Render individual quota item
    function renderQuotaItem(name, quota) {
        if (!quota || quota.limit < 0) {
            return `
                <div class="quota-item">
                    <h5>${name}</h5>
                    <div>Unlimited</div>
                </div>
            `;
        }
        
        const percent = quota.limit > 0 ? (quota.used / quota.limit) * 100 : 0;
        let barClass = 'low';
        if (percent > 80) barClass = 'high';
        else if (percent > 60) barClass = 'medium';
        
        return `
            <div class="quota-item">
                <h5>${name}</h5>
                <div>${quota.used} / ${quota.limit}</div>
                <div class="quota-bar">
                    <div class="quota-bar-fill ${barClass}" style="width: ${percent}%"></div>
                </div>
                <small>${quota.free} available</small>
            </div>
        `;
    }

    // Event handlers
    sendBtn.click(sendMessage);
    clearBtn.click(function() {
        chatMessages.html(`
            <div class="message assistant">
                <strong>AI Assistant:</strong> 
                Chat cleared. How can I help you with your OpenStack infrastructure?
            </div>
        `);
    });

    chatInput.keypress(function(e) {
        if (e.which === 13) sendMessage();
    });

    chatInput.focus();
});
</script>
{% endblock %}
EOF
}

create_urls_integration() {
    echo "Creating URL integration..."
    
    # API URLs for the dashboard
    cat > "$HORIZON_DIR/dashboards/mistral_ai/chat/api_urls.py" << 'EOF'
from django.urls import re_path
import sys
import os

# Add Mistral AI installation directory to Python path
sys.path.insert(0, '/opt/mistral-openstack')

try:
    from horizon_api import chat_api, tools_api, quota_api, test_api_key
except ImportError:
    # Fallback if horizon_api not available
    from django.http import JsonResponse
    from django.views.decorators.csrf import csrf_exempt
    
    @csrf_exempt
    def chat_api(request):
        return JsonResponse({'error': 'Mistral AI agent not available'}, status=503)
    
    @csrf_exempt
    def tools_api(request):
        return JsonResponse({'tools': [], 'total_count': 0})
    
    @csrf_exempt
    def quota_api(request):
        return JsonResponse({'error': 'Quota service not available'}, status=503)
    
    @csrf_exempt
    def test_api_key(request):
        return JsonResponse({'valid': False, 'error': 'Service not available'}, status=503)

urlpatterns = [
    re_path(r'^chat/$', chat_api, name='chat_api'),
    re_path(r'^tools/$', tools_api, name='tools_api'),
    re_path(r'^quota/$', quota_api, name='quota_api'),
    re_path(r'^test-key/$', test_api_key, name='test_api_key'),
]
EOF
    
    # Update main urls.py to include API
    cat >> "$HORIZON_DIR/dashboards/mistral_ai/chat/urls.py" << 'EOF'

# Include API URLs
from django.urls import include
from . import api_urls

urlpatterns += [
    re_path(r'^api/', include(api_urls)),
]
EOF
}

create_enabled_file() {
    echo "Creating Horizon enabled file..."
    cat > "$HORIZON_DIR/enabled/_90_mistral_ai.py" << 'EOF'
# Enable Mistral AI dashboard
DASHBOARD = 'mistral_ai'

# The slug of the panel group to be added to HORIZON_CONFIG. Required.
PANEL_GROUP = 'mistral_ai'

# The slug of the dashboard to be added to HORIZON_CONFIG. Required.
PANEL_DASHBOARD = 'project'

# If set, it will update the default panel of the PANEL_DASHBOARD.
DEFAULT_PANEL = None

ADD_INSTALLED_APPS = [
    'openstack_dashboard.dashboards.mistral_ai',
]

ADD_ANGULAR_MODULES = []

AUTO_DISCOVER_STATIC_FILES = True
DISABLED = False
EOF
}

# ── Main Installation ────────────────────────────────────────────────────────

echo "Installing Mistral AI Horizon Dashboard Panel..."

# Check if core installation exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Error: Core installation not found at $INSTALL_DIR"
    echo "Please run 13-mistral-ai-core.sh first"
    exit 1
fi

# Check if Horizon is installed
if [[ ! -d "$HORIZON_DIR" ]]; then
    echo "Error: Horizon not found at $HORIZON_DIR"
    echo "Please install Horizon first or update HORIZON_DIR path"
    exit 1
fi

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Create Horizon integration components
create_horizon_api
create_dashboard_panel
create_templates
create_urls_integration
create_enabled_file

# Set proper ownership
chown -R horizon:horizon "$HORIZON_DIR/dashboards/mistral_ai" || true
chown -R horizon:horizon "$HORIZON_DIR/enabled/_90_mistral_ai.py" || true

# Restart Apache to reload Horizon
systemctl restart apache2

echo ""
echo "✓ Mistral AI Horizon Dashboard Panel installed"
echo ""
echo "Setup:"
echo "  1. Navigate to Horizon dashboard at http://127.0.0.1/horizon/"
echo "  2. Login with admin/changeit"
echo "  3. Click 'Mistral AI' in the left sidebar → 'AI Assistant'"
echo "  4. Enter your Mistral AI API key in the configuration panel"
echo "  5. Click 'Save & Test' to validate and store your key"
echo ""
echo "Access:"
echo "  • Navigate to Horizon dashboard"
echo "  • Look for 'Mistral AI' tab in the left sidebar"
echo "  • Click 'AI Assistant' to start using the chat interface"
echo "  • Configure your API key in the settings panel"
echo ""
echo "Features:"
echo "  • Secure API key management with session storage"
echo "  • API key validation and testing"
echo "  • Natural language OpenStack operations"
echo "  • Real-time quota monitoring"
echo "  • Dry-run mode for safe testing"  
echo "  • Tool capabilities overview"
echo "  • Integrated transaction rollback"
echo ""
echo "✓ Mistral AI OpenStack integration complete!"