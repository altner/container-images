#!/bin/sh
# Setzt die Zeitstempel aller Einträge unter <verzeichnis> auf SOURCE_DATE_EPOCH,
# damit gleicher Inhalt die gleiche Image-Schicht ergibt.
#
# Aufruf: SOURCE_DATE_EPOCH=<sekunden> normalize-epoch.sh <verzeichnis>
set -eu

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH ist nicht gesetzt}"
find "$1" -depth -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
