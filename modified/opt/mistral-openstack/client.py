import os
from mistralai.client import MistralClient
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(
    wait=wait_exponential(multiplier=1, min=2, max=30),
    stop=stop_after_attempt(3),
)
def get_mistral_client() -> MistralClient:
    api_key = os.environ.get("MISTRAL_API_KEY")
    if not api_key:
        raise RuntimeError("MISTRAL_API_KEY is not set")
    
    # Create client with API key
    return MistralClient(api_key=api_key)
