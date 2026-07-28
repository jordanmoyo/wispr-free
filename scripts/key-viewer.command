#!/bin/zsh
# Live viewer for Wispr's diagnostic log — visual proof of key detection.
clear
echo "╔══════════════════════════════════════════════════╗"
echo "║   WISPR LIVE KEY VIEWER                          ║"
echo "║   Press and hold Fn — lines appear here live.    ║"
echo "║   (Ctrl+C or close window to quit)               ║"
echo "╚══════════════════════════════════════════════════╝"
echo
LOG="$HOME/Library/Application Support/Wispr/wispr.log"
touch "$LOG"
tail -n 0 -f "$LOG" | while IFS= read -r line; do
  case "$line" in
    *"transition DOWN"*)      echo "🔴  Fn PRESSED  — recording should start  ($line)" ;;
    *"transition UP"*)        echo "⚪  Fn RELEASED — transcribing…            ($line)" ;;
    *"event #"*)              echo "👀  keyboard event reached Wispr           ($line)" ;;
    *"tap disabled"*)         echo "⛔  OS BLOCKED the key listener (permission problem)  ($line)" ;;
    *"transcribed"*)          echo "📝  $line" ;;
    *"delivered"*)            echo "📋  $line" ;;
    *"recorded"*)             echo "🎙   $line" ;;
    *)                        echo "    $line" ;;
  esac
done
