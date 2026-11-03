"""
Compatibility entry point for AKL Revival repository metadata generation.

The PowerShell generator is the authoritative implementation.
This wrapper ensures both entry points use identical validation and output.
"""

from pathlib import Path
import subprocess
import sys


def main():
    generator = Path(__file__).resolve().with_name("generate_repo.ps1")

    if not generator.is_file():
        print(f"ERROR: PowerShell generator not found: {generator}", file=sys.stderr)
        return 1

    command = [
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(generator),
    ]

    try:
        result = subprocess.run(command, check=False)
    except OSError as exc:
        print(f"ERROR: Could not start PowerShell generator: {exc}", file=sys.stderr)
        return 1

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
