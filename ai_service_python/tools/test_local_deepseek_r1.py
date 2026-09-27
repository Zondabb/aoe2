#!/usr/bin/env python3
"""Same OpenAI-compat call that works on the Ollama box.

On the Ollama machine:
  python ai_service_python/tools/test_local_deepseek_r1.py --base-url http://127.0.0.1:11434/v1

From another PC on the LAN:
  python ai_service_python/tools/test_local_deepseek_r1.py
"""

from __future__ import annotations

import argparse
import sys

DEFAULT_BASE = "http://192.168.1.103:11434/v1"
DEFAULT_MODEL = "deepseek-r1:8b"
DEFAULT_PROMPT = "你好"


def openai_base(url: str) -> str:
    base = url.rstrip("/")
    return base if base.endswith("/v1") else f"{base}/v1"


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description="Test local DeepSeek-R1 via OpenAI SDK")
    parser.add_argument("--base-url", default=DEFAULT_BASE)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--api-key", default="ollama")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    args = parser.parse_args()

    try:
        from openai import OpenAI
    except ImportError:
        print("缺少 openai 包，先执行: pip install openai", file=sys.stderr)
        return 1

    base = openai_base(args.base_url)
    print(f"POST {base}/chat/completions  model={args.model}")
    client = OpenAI(base_url=base, api_key=args.api_key)
    resp = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": args.prompt}],
    )
    message = resp.choices[0].message
    content = message.content
    reasoning = getattr(message, "reasoning_content", None) or getattr(message, "reasoning", None)
    if reasoning:
        print(reasoning)
        print("---")
    print(content or "(empty content)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
