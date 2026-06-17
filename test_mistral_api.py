#!/usr/bin/env python3

import os
import sys

def test_mistral_api():
    api_key = input("Enter your Mistral AI API key: ").strip()
    
    if not api_key:
        print("No API key provided")
        return
    
    print(f"Testing API key (length: {len(api_key)})...")
    
    try:
        # Set environment variable
        os.environ['MISTRAL_API_KEY'] = api_key
        
        # Import and test
        from mistralai import Mistral
        
        print("Creating Mistral client...")
        client = Mistral(api_key=api_key)
        
        print("Making test API call...")
        response = client.chat.complete(
            model="mistral-large-latest",
            messages=[{"role": "user", "content": "Hello"}],
            max_tokens=5
        )
        
        if response and response.choices:
            print("✅ API key is valid!")
            print(f"Response: {response.choices[0].message.content}")
        else:
            print("❌ API returned empty response")
            
    except Exception as e:
        print(f"❌ Error: {e}")
        print(f"Error type: {type(e).__name__}")
        
        # Check if it's a known error type
        error_str = str(e).lower()
        if "401" in error_str or "unauthorized" in error_str:
            print("This looks like an invalid API key error")
        elif "403" in error_str or "forbidden" in error_str:
            print("This looks like a permissions error")
        elif "import" in error_str or "module" in error_str:
            print("This looks like a missing dependency error")
        else:
            print("Unknown error - please check the full error message above")

if __name__ == "__main__":
    test_mistral_api()