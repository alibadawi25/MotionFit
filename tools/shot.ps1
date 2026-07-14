<#
  shot.ps1 — PowerShell wrapper around tools/shot.sh (the real logic lives there).
  Runs the bash tool via Git Bash so you don't have to drop into a bash shell.

  Usage:
    .\tools\shot.ps1                       # main scene -> tools/shots/shot.png
    .\tools\shot.ps1 menu                  # -> tools/shots/menu.png
    .\tools\shot.ps1 openworld res://scenes/open-world/open-world.tscn

  Set $env:GODOT if your Godot 4.7 executable lives somewhere else.
#>
param(
  [string]$Name  = "shot",
  [string]$Scene = ""
)

$bash = "$env:ProgramFiles\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { $bash = "bash" }  # fall back to PATH

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here "shot.sh"

& $bash "$script" $Name $Scene
