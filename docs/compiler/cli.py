#!/usr/bin/env python3
"""Command-line entry for the DJB markdown compiler."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from compile import compile_file


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compile markdown into DJB-style HTML pages.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        type=Path,
        help="markdown file(s) (.md)",
    )
    parser.add_argument(
        "-o",
        "--out",
        type=Path,
        default=None,
        help="output directory for {stem}.html (default: beside each input)",
    )
    parser.add_argument(
        "--dark",
        action="store_true",
        help="start in dark mode (theme checkbox checked; still toggleable)",
    )
    parser.add_argument(
        "--domain",
        default=None,
        help="apex domain for ${domain} placeholders (default: $DOMAIN or .env)",
    )
    args = parser.parse_args(argv)

    bad = False
    for input_path in args.inputs:
        if not input_path.is_file():
            print(f"error: not a file: {input_path}", file=sys.stderr)
            bad = True
        elif input_path.suffix.lower() != ".md":
            print(f"error: not a markdown file: {input_path}", file=sys.stderr)
            bad = True
    if bad:
        return 1

    if args.out is not None:
        if args.out.exists() and not args.out.is_dir():
            print(f"error: not a directory: {args.out}", file=sys.stderr)
            return 1
        args.out.mkdir(parents=True, exist_ok=True)

    for input_path in args.inputs:
        if args.out is not None:
            output_path = args.out / f"{input_path.stem.lower()}.html"
        else:
            output_path = None

        try:
            out = compile_file(
                input_path,
                output_path,
                dark=args.dark,
                domain=args.domain,
            )
        except ValueError as exc:
            print(f"error: {input_path}: {exc}", file=sys.stderr)
            return 1
        print(out)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
