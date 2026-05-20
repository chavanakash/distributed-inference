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


def _build_prompt(messages: List[Dict[str, Any]]) -> str:
    prompt = ""
    for msg in messages:
        role = "model" if msg["role"] == "assistant" else msg["role"]
        prompt += f"<start_of_turn>{role}\n{msg['content']}<end_of_turn>\n"
    prompt += "<start_of_turn>model\n"
    return prompt


def run_inference_handler(payload: Dict[str, Any]) -> str:
    messages = payload.get("messages", [])
    prompt = _build_prompt(messages)

    response = model(prompt, max_tokens=64, stop=["<end_of_turn>"])
    result = response["choices"][0]["text"].strip()
    print(result)
    return result


iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")
