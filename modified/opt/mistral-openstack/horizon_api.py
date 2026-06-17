"""
Horizon API integration for Mistral AI OpenStack agent.
Provides Django-compatible views and utilities.
"""

import json
import logging
import subprocess
import os
import re
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

log = logging.getLogger("mistral-os.horizon")

@csrf_exempt
def chat_api(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    
    try:
        data = json.loads(request.body)
        user_message = data.get('message', '').strip()
        dry_run = data.get('dry_run', False)
        api_key = data.get('api_key', '').strip()
        
        if not user_message:
            return JsonResponse({'error': 'Message is required'}, status=400)
        
        if not api_key:
            return JsonResponse({'error': 'Mistral AI API key is required'}, status=400)
        
        # Enhance the message to encourage tool usage over instructions
        action_words = ['create', 'launch', 'build', 'deploy', 'delete', 'remove', 'start', 'stop', 'configure', 'setup']
        if any(word in user_message.lower() for word in action_words):
            enhanced_message = f"CRITICAL: DO NOT provide instructions or ask questions. IMMEDIATELY call the appropriate tool function now: {user_message}"
        else:
            enhanced_message = user_message

        # Set up environment for the agent
        env = os.environ.copy()
        env['MISTRAL_API_KEY'] = api_key
        env['OS_USERNAME'] = 'admin'
        env['OS_PASSWORD'] = 'changeit'
        env['OS_PROJECT_NAME'] = 'admin'
        env['OS_USER_DOMAIN_NAME'] = 'Default'
        env['OS_PROJECT_DOMAIN_NAME'] = 'Default'
        env['OS_AUTH_URL'] = 'http://127.0.0.1:5000/v3'
        env['OS_IDENTITY_API_VERSION'] = '3'
        env['PYTHONPATH'] = '/opt/mistral-openstack'
        env['HOME'] = '/tmp'
        env['PYTHONIOENCODING'] = 'utf-8'
        env['LC_ALL'] = 'C.UTF-8'
        env['LANG'] = 'C.UTF-8'
        
        # Run the agent directly as www-data (no sudo needed)
        cmd = ['/opt/mistral-openstack/venv/bin/python3', '/opt/mistral-openstack/agent.py']
        if dry_run:
            cmd.append('--dry-run')
        cmd.extend(['--single', enhanced_message])
        
        try:
            result = subprocess.run(
                cmd,
                input='',
                capture_output=True,
                text=True,
                timeout=120,
                env=env,
                cwd='/opt/mistral-openstack',
                encoding='utf-8',
                errors='replace'
            )
            
            # Log the raw output for debugging (truncated)
            log.info(f"Agent return code: {result.returncode}")
            if result.stderr:
                log.error(f"Agent stderr: {result.stderr[:500]}")
            
            if result.returncode == 0:
                # Extract just the response text (skip log lines)
                output_lines = result.stdout.strip().split('\n')
                response_lines = []
                for line in output_lines:
                    # Skip log lines that contain timestamps and log levels
                    if not any(x in line for x in ['[INFO]', '[ERROR]', '[DEBUG]', '[WARNING]']):
                        response_lines.append(line)
                
                response_text = '\n'.join(response_lines).strip() or 'Operation completed successfully'
                
                # Convert markdown-style formatting to HTML for better readability
                response_html = response_text
                
                # Convert markdown headers
                response_html = re.sub(r'^### (.+)$', r'<h3>\1</h3>', response_html, flags=re.MULTILINE)
                response_html = re.sub(r'^## (.+)$', r'<h2>\1</h2>', response_html, flags=re.MULTILINE)
                response_html = re.sub(r'^# (.+)$', r'<h1>\1</h1>', response_html, flags=re.MULTILINE)
                
                # Convert markdown bold
                response_html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', response_html)
                
                # Convert markdown code blocks
                response_html = re.sub(r'```bash\n(.*?)\n```', r'<pre><code>\1</code></pre>', response_html, flags=re.DOTALL)
                response_html = re.sub(r'```\n(.*?)\n```', r'<pre><code>\1</code></pre>', response_html, flags=re.DOTALL)
                
                # Convert inline code
                response_html = re.sub(r'`(.+?)`', r'<code>\1</code>', response_html)
                
                # Convert markdown tables to HTML
                lines = response_html.split('\n')
                html_lines = []
                in_table = False
                
                for i, line in enumerate(lines):
                    if '|' in line and not in_table:
                        # Start of table
                        in_table = True
                        html_lines.append('<table class="table table-striped">')
                        # Check if next line is a separator
                        if i + 1 < len(lines) and '---' in lines[i + 1]:
                            # Header row
                            cells = [cell.strip() for cell in line.split('|')[1:-1]]
                            html_lines.append('<thead><tr>')
                            for cell in cells:
                                html_lines.append(f'<th>{cell}</th>')
                            html_lines.append('</tr></thead><tbody>')
                        else:
                            # Regular row
                            cells = [cell.strip() for cell in line.split('|')[1:-1]]
                            html_lines.append('<tr>')
                            for cell in cells:
                                html_lines.append(f'<td>{cell}</td>')
                            html_lines.append('</tr>')
                    elif '|' in line and in_table:
                        if '---' in line:
                            # Skip separator line
                            continue
                        # Table row
                        cells = [cell.strip() for cell in line.split('|')[1:-1]]
                        html_lines.append('<tr>')
                        for cell in cells:
                            html_lines.append(f'<td>{cell}</td>')
                        html_lines.append('</tr>')
                    elif in_table and '|' not in line:
                        # End of table
                        html_lines.append('</tbody></table>')
                        in_table = False
                        html_lines.append(line)
                    else:
                        html_lines.append(line)
                
                if in_table:
                    html_lines.append('</tbody></table>')
                
                response_html = '\n'.join(html_lines)
                
                # Convert newlines to HTML line breaks
                response_html = response_html.replace('\n', '<br>')
                
                return JsonResponse({
                    'response': response_html,
                    'dry_run': dry_run,
                    'timestamp': None
                })
            else:
                error_msg = result.stderr.strip() or f'Agent failed with exit code {result.returncode}'
                log.error(f"Agent failed with return code {result.returncode}")
                return JsonResponse({'error': f'Agent error: {error_msg}'}, status=500)
                
        except subprocess.TimeoutExpired:
            log.error("Agent timeout")
            return JsonResponse({'error': 'Request timeout - operation took too long'}, status=500)
        except Exception as e:
            log.error(f"Failed to run agent: {str(e)}")
            return JsonResponse({'error': f'Failed to run agent: {str(e)}'}, status=500)
        
    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON'}, status=400)
    except Exception as exc:
        log.error(f"Chat request failed: {exc}")
        return JsonResponse({'error': str(exc)}, status=500)

@csrf_exempt
def tools_api(request):
    if request.method != 'GET':
        return JsonResponse({'error': 'GET required'}, status=405)
    
    try:
        # Try to get tools from the agent installation
        env = {
            'PYTHONPATH': '/opt/mistral-openstack', 
            'HOME': '/tmp',
            'PYTHONIOENCODING': 'utf-8',
            'LC_ALL': 'C.UTF-8',
            'LANG': 'C.UTF-8'
        }
        result = subprocess.run(
            ['/opt/mistral-openstack/venv/bin/python3', '-c', '''
import sys
sys.path.insert(0, "/opt/mistral-openstack")
try:
    from tools import TOOLS, DESTRUCTIVE_TOOLS
    import json
    tools_info = []
    for tool in TOOLS:
        func_info = tool["function"]
        tools_info.append({
            "name": func_info["name"],
            "description": func_info["description"],
            "destructive": func_info["name"] in DESTRUCTIVE_TOOLS
        })
    print(json.dumps({"tools": tools_info, "total_count": len(tools_info)}))
except ImportError:
    print(json.dumps({"tools": [], "total_count": 0, "error": "Tools not installed"}))
'''],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
            cwd='/opt/mistral-openstack',
            encoding='utf-8',
            errors='replace'
        )
        
        if result.returncode == 0:
            try:
                tools_data = json.loads(result.stdout.strip())
                return JsonResponse(tools_data)
            except json.JSONDecodeError:
                pass
                
    except Exception:
        pass
    
    return JsonResponse({
        'tools': [],
        'total_count': 0,
        'error': 'Tools not available - install scripts 14-17'
    })

@csrf_exempt
def quota_api(request):
    if request.method != 'GET':
        return JsonResponse({'error': 'GET required'}, status=405)
    
    try:
        # Set up OpenStack environment
        env = {
            'OS_USERNAME': 'admin',
            'OS_PASSWORD': 'changeit',
            'OS_PROJECT_NAME': 'admin',
            'OS_USER_DOMAIN_NAME': 'Default',
            'OS_PROJECT_DOMAIN_NAME': 'Default',
            'OS_AUTH_URL': 'http://127.0.0.1:5000/v3',
            'OS_IDENTITY_API_VERSION': '3',
            'PYTHONPATH': '/opt/mistral-openstack',
            'HOME': '/tmp',
            'PYTHONIOENCODING': 'utf-8',
            'LC_ALL': 'C.UTF-8',
            'LANG': 'C.UTF-8'
        }
        
        result = subprocess.run(
            ['/opt/mistral-openstack/venv/bin/python3', '-c', '''
import sys
sys.path.insert(0, "/opt/mistral-openstack")
try:
    from quota import get_compute_headroom, get_network_headroom
    import json
    compute = get_compute_headroom()
    network = get_network_headroom()
    print(json.dumps({"compute": compute, "network": network}))
except ImportError as e:
    print(json.dumps({"error": f"Quota module not available: {e}"}))
except Exception as e:
    print(json.dumps({"error": f"Quota check failed: {e}"}))
'''],
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
            cwd='/opt/mistral-openstack',
            encoding='utf-8',
            errors='replace'
        )
        
        if result.returncode == 0:
            try:
                quota_data = json.loads(result.stdout.strip())
                return JsonResponse(quota_data)
            except json.JSONDecodeError:
                pass
                
    except Exception:
        pass
    
    return JsonResponse({
        'error': 'Quota service not available'
    }, status=503)

@csrf_exempt
def test_api_key(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    
    try:
        data = json.loads(request.body)
        api_key = data.get('api_key', '').strip()
        
        if not api_key:
            return JsonResponse({'valid': False, 'error': 'API key is required'})
        
        if len(api_key) < 10:
            return JsonResponse({'valid': False, 'error': 'API key too short'})
        
        # Test with curl
        curl_cmd = [
            'curl', '-s', '-w', '%{http_code}',
            '-H', 'Content-Type: application/json',
            '-H', f'Authorization: Bearer {api_key}',
            '-d', '{"model":"mistral-small","messages":[{"role":"user","content":"test"}],"max_tokens":5}',
            '--max-time', '10',
            'https://api.mistral.ai/v1/chat/completions'
        ]
        
        try:
            result = subprocess.run(curl_cmd, capture_output=True, text=True, timeout=15)
            
            if result.stdout and '200' in result.stdout:
                return JsonResponse({'valid': True, 'message': 'API key valid'})
            elif result.stdout and '401' in result.stdout:
                return JsonResponse({'valid': False, 'error': 'Invalid API key'})
            else:
                return JsonResponse({'valid': False, 'error': 'API test failed'})
                
        except subprocess.TimeoutExpired:
            return JsonResponse({'valid': False, 'error': 'Request timeout'})
        except Exception as e:
            return JsonResponse({'valid': False, 'error': f'Test failed: {str(e)}'})
            
    except json.JSONDecodeError:
        return JsonResponse({'valid': False, 'error': 'Invalid JSON'})
    except Exception as exc:
        log.error(f"API key test failed: {exc}")
        return JsonResponse({'valid': False, 'error': str(exc)}, status=500)
