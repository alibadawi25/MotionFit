<#
  check.ps1 — PowerShell wrapper around tools/check.sh (the real logic lives there).
  Boots the project headless and reports any script/parse errors. Runs via Git Bash.

  Usage:
    .\tools\check.ps1                                    # boots the main scene
    .\tools\check.ps1 res://scenes/menus/settings_menu.tscn

  Set $env:GODOT if your Godot 4.7 executable lives somewhere else.
  Exit code is 0 when clean, 1 when errors are found.
#>
param(
  [string]$Scene = ""
)

$bash = "$env:ProgramFiles\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { $bash = "bash" }  # fall back to PATH

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here "check.sh"

& $bash "$script" $Scene
exit $LASTEXITCODE
