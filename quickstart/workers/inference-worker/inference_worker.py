import os
from typing import Any, Dict, List

from iii import InitOptions, Logger, register_worker

iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="inference-worker"),
)
logger = Logger()

from llama_cpp import Llama

model = Llama.from_pretrained(
    repo_id="ggml-org/gemma-3-270m-GGUF",
    filename="gemma-3-270m-Q8_0.gguf",
    n_ctx=512,
    n_threads=1,
    verbose=False,
)


def run_inference_handler(payload: Dict[str, Any]) -> str:
    messages = payload.get("messages", [])

    response = model.create_chat_completion(
        messages=messages,
        max_tokens=64,
    )
    result = response["choices"][0]["message"]["content"]
    print(result)
    return result


iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")
