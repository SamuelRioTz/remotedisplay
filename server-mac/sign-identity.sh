#!/bin/bash
# Prints the code-signing identity to use for Remote Display, chosen by TEAM, never by
# name: this Mac has two "Apple Development: Samuel Rioja" certificates, one issued to
# Trufi Association e.V. (team NNB9PHQ49J) and one to Sam's personal account (team
# K45698KZ4W). Only the personal team may sign this project. A "Developer ID
# Application" certificate of that team wins (distribution outside the App Store);
# otherwise its "Apple Development" one. Prints nothing if the team has no identity.
# Usage: sign-identity.sh [TEAM_ID]   (default K45698KZ4W)
TEAM="${1:-K45698KZ4W}"
pick() { # $1 = certificate kind
  security find-identity -v -p codesigning 2>/dev/null | grep -o "\"$1: [^\"]*\"" | tr -d '"' | while read -r name; do
    ou=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
    if [ "$ou" = "$TEAM" ]; then echo "$name"; return 0; fi
  done
  return 1
}
pick "Developer ID Application" || pick "Apple Development"
