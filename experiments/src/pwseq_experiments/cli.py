from __future__ import annotations

import argparse


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("bootstrap")
    sub.add_parser("prepare")
    sub.add_parser("preflight")
    sub.add_parser("freeze")
    run_parser = sub.add_parser("run")
    run_parser.add_argument(
        "stage",
        choices=["hard", "audit", "aggregation", "generation", "noise", "replication", "all"],
    )
    sub.add_parser("analyze")
    sub.add_parser("archive")
    args = parser.parse_args(argv)
    try:
        if args.command == "bootstrap":
            from .bootstrap import bootstrap
            bootstrap()
        elif args.command == "prepare":
            from .prepare import prepare_data
            prepare_data()
        elif args.command == "preflight":
            from .preflight import preflight
            if not preflight()["full_ok"]:
                raise RuntimeError("full experiment preflight failed")
        elif args.command == "freeze":
            from .freeze import freeze
            freeze()
        elif args.command == "run":
            from .run import run_stage
            run_stage(args.stage)
        elif args.command == "analyze":
            from .analysis import analyze
            analyze()
        elif args.command == "archive":
            from .archive import archive
            archive()
        return 0
    except Exception as exc:
        from .common import issue
        issue(args.command, exc)
        raise
