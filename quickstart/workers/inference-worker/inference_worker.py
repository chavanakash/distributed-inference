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

    # gemma-3-270m is a base model — use few-shot Q&A completion format
    prompt = "Q: What is 1+1?\nA: 2\n\nQ: What color is the sky?\nA: Blue\n\n"
    for msg in messages:
        if msg["role"] == "user":
            prompt += f"Q: {msg['content']}\nA:"
        elif msg["role"] == "assistant":
            prompt += f" {msg['content']}\n\n"

    response = model(prompt, max_tokens=32, stop=["\n", "Q:"])
    result = response["choices"][0]["text"].strip()
    print(result)
    return result


iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")
