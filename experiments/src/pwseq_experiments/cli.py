from __future__ import annotations

import argparse
import os


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("bootstrap")
    sub.add_parser("bootstrap-static")
    sub.add_parser("prepare")
    sub.add_parser("preflight")
    sub.add_parser("freeze")
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--run-id", required=True)
    run_parser.add_argument(
        "stage",
        choices=["hard", "audit", "aggregation", "generation", "noise", "replication", "mixed", "design", "all"],
    )
    analyze_parser = sub.add_parser("analyze")
    analyze_parser.add_argument("--run-id", required=True)
    archive_parser = sub.add_parser("archive")
    archive_parser.add_argument("--run-id", required=True)
    power_parser = sub.add_parser("power")
    power_parser.add_argument("--run-id", required=True)
    finalize_parser = sub.add_parser("finalize-design")
    finalize_parser.add_argument("--run-id", required=True)
    args = parser.parse_args(argv)
    if hasattr(args, "run_id"):
        os.environ["PWSEQ_RUN_ID"] = args.run_id
    try:
        if args.command == "bootstrap":
            from .bootstrap import bootstrap
            bootstrap()
        elif args.command == "bootstrap-static":
            from .bootstrap_static import bootstrap_static
            bootstrap_static()
        elif args.command == "prepare":
            from .prepare import prepare_data
            prepare_data()
        elif args.command == "preflight":
            from .preflight import preflight
            if not preflight()["full_ok"]:
                raise RuntimeError("full experiment preflight failed")
        elif args.command == "freeze":
            from .freeze import freeze
            print(freeze()["run_id"])
        elif args.command == "run":
            from .run import run_stage
            run_stage(args.stage)
        elif args.command == "analyze":
            from .analysis import analyze
            analyze()
        elif args.command == "archive":
            from .archive import archive
            archive()
        elif args.command == "power":
            from .power import power_analysis
            power_analysis()
        elif args.command == "finalize-design":
            from .power import finalize_design
            finalize_design()
        return 0
    except Exception as exc:
        from .common import issue
        issue(args.command, exc)
        raise
