#!/bin/sh
# PROTOTYPE: open the demo workspace (storefront + orders-service) with the deep-dive panel prototype.
#   ./run.sh          minimal config (leader = space)
#   ./run.sh --mine   your own nvim config + the prototype (your leader)
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/demo" || exit 1
FILE=storefront/src/features/checkout/CheckoutPage.tsx
if [ "$1" = "--mine" ]; then
  exec nvim --cmd "set rtp^=$HERE" -c "lua require('deepdive_proto').setup(); require('deepdive_proto.qa_views').setup(); require('deepdive_proto.bd_views').setup()" "$FILE"
fi
exec nvim -u "$HERE/init.lua" "$FILE"
