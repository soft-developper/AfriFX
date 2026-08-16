#!/usr/bin/env bash
# ============================================================
# 9b-pagination-user-lists.sh   (run AFTER 9a; deploy web)
#
# Item 4, part 2 of 3: wire usePaged + Pager into the three user-side lists.
#   - My trades      : paginate `filtered` (20/page).
#   - History        : paginate the `standalone` list (the growing part). Corridor
#                      groups stay above, un-paginated (they're few and grouped).
#   - Recent bridges : replace the hard `rows.slice(0, 8)` cap with 20/page.
#
# Each keeps its existing filters/loading/empty states; pagination just wraps
# the render + adds a Pager under the list.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

MT="$WEB/app/(app)/my-trades/page.tsx"
HI="$WEB/app/(app)/history/page.tsx"
BR="$WEB/components/bridge/BridgeHistory.tsx"
for f in "$MT" "$HI" "$BR"; do [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }; done
[ -f "$WEB/hooks/usePaged.ts" ] || { echo "ERROR: run 9a first (usePaged.ts missing)"; exit 1; }

# ---------- My trades ----------
PL1="$(mktemp /tmp/mt.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

my $imp_old = "import type { P2POffer } from '\@/types'";
my $imp_new = "import type { P2POffer } from '\@/types'\n"
            . "import { usePaged } from '\@/hooks/usePaged'\n"
            . "import { Pager } from '\@/components/ui/pager'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "MT import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# add usePaged after `filtered`
my $flt_old = "  const filtered = filter === 'all' ? offers : offers.filter(o => o.status === filter)";
my $flt_new = $flt_old . "\n  const pg = usePaged(filtered, 20)";
$c = () = $s =~ /\Q$flt_old\E/g; die "MT filtered anchor: found $c\n" unless $c==1;
$s =~ s/\Q$flt_old\E/$flt_new/;

# map paged items instead of all
my $map_old = "      <div className=\"space-y-3\">\n        {filtered.map((offer) => {";
my $map_new = "      <div className=\"space-y-3\">\n        {pg.pageItems.map((offer) => {";
$c = () = $s =~ /\Q$map_old\E/g; die "MT map anchor: found $c\n" unless $c==1;
$s =~ s/\Q$map_old\E/$map_new/;

# add Pager after the list closes
my $close_old = "        })}\n      </div>\n    </div>\n  )\n}";
my $close_new = "        })}\n      </div>\n\n      <Pager {...pg} label=\"trades\" />\n    </div>\n  )\n}";
$c = () = $s =~ /\Q$close_old\E/g; die "MT close anchor: found $c\n" unless $c==1;
$s =~ s/\Q$close_old\E/$close_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "my-trades: paginated.\n";
PERL
perl "$PL1" "$MT"; rm -f "$PL1"

# ---------- History (paginate standalone) ----------
PL2="$(mktemp /tmp/hi.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

my $imp_old = "import { chainByKey } from '\@/lib/cctp-chains'";
my $imp_new = "import { chainByKey } from '\@/lib/cctp-chains'\n"
            . "import { usePaged } from '\@/hooks/usePaged'\n"
            . "import { Pager } from '\@/components/ui/pager'";
my $c = () = $s =~ /\Q$imp_old\E/g;
die "HI import anchor: found $c (did 8-history-bridge-labels.sh run? it adds chainByKey)\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# paginate the standalone array (declared as `const standalone: any[] = []`)
my $decl_old = "  const standalone: any[] = [];";
my $decl_new = "  const standalone: any[] = [];";  # unchanged; we add pg after the forEach fills it
$c = () = $s =~ /\Q$decl_old\E/g; die "HI standalone decl anchor: found $c\n" unless $c==1;

# Insert usePaged right after the forEach that fills corridorGroups/standalone.
my $fe_old = "    } else {\n      standalone.push(tx)\n    }\n  })";
my $fe_new = "    } else {\n      standalone.push(tx)\n    }\n  })\n\n  const pg = usePaged(standalone, 20)";
$c = () = $s =~ /\Q$fe_old\E/g; die "HI forEach anchor: found $c\n" unless $c==1;
$s =~ s/\Q$fe_old\E/$fe_new/;

# render paged standalone instead of all
my $map_old = "        {/* Standalone */}\n        {standalone.map((tx: any) => (";
my $map_new = "        {/* Standalone */}\n        {pg.pageItems.map((tx: any) => (";
$c = () = $s =~ /\Q$map_old\E/g; die "HI map anchor: found $c\n" unless $c==1;
$s =~ s/\Q$map_old\E/$map_new/;

# add Pager after the standalone list block closes (the ))} then </div></div>)
my $close_old = "        {standalone.map((tx: any) => (\n          <div key={tx.id} className=\"rounded-xl border border-app-border bg-app-surface\">\n            <TxRow tx={tx} />\n          </div>\n        ))}\n      </div>\n    </div>\n  )\n}";
# NOTE we already swapped the map head above, so match the swapped version:
my $close_old2 = "        {pg.pageItems.map((tx: any) => (\n          <div key={tx.id} className=\"rounded-xl border border-app-border bg-app-surface\">\n            <TxRow tx={tx} />\n          </div>\n        ))}\n      </div>\n    </div>\n  )\n}";
my $close_new = "        {pg.pageItems.map((tx: any) => (\n          <div key={tx.id} className=\"rounded-xl border border-app-border bg-app-surface\">\n            <TxRow tx={tx} />\n          </div>\n        ))}\n      </div>\n\n      <Pager {...pg} label=\"transactions\" />\n    </div>\n  )\n}";
$c = () = $s =~ /\Q$close_old2\E/g; die "HI close anchor: found $c\n" unless $c==1;
$s =~ s/\Q$close_old2\E/$close_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "history: standalone list paginated.\n";
PERL
perl "$PL2" "$HI"; rm -f "$PL2"

# ---------- Recent bridges ----------
PL3="$(mktemp /tmp/br.XXXXXX.pl)"
cat > "$PL3" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

my $imp_old = "import { chainByKey } from '\@/lib/cctp-chains'";
my $imp_new = "import { chainByKey } from '\@/lib/cctp-chains'\n"
            . "import { usePaged } from '\@/hooks/usePaged'\n"
            . "import { Pager } from '\@/components/ui/pager'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "BR import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# add usePaged over rows just before the early return guard.
my $guard_old = "  if (!address || (!rows.length && !loading)) return null";
my $guard_new = "  const pg = usePaged(rows, 20)\n\n  if (!address || (!rows.length && !loading)) return null";
$c = () = $s =~ /\Q$guard_old\E/g; die "BR guard anchor: found $c\n" unless $c==1;
$s =~ s/\Q$guard_old\E/$guard_new/;

# replace the hard slice(0,8) with paged items.
my $map_old = "        {rows.slice(0, 8).map(r => {";
my $map_new = "        {pg.pageItems.map(r => {";
$c = () = $s =~ /\Q$map_old\E/g; die "BR map anchor: found $c\n" unless $c==1;
$s =~ s/\Q$map_old\E/$map_new/;

# add Pager after the list container closes. The list is:
#   <div className="space-y-2"> ... {map ...} </div>
# followed by the component's closing </div>. Anchor on that unique pair.
my $close_old = "          )\n        })}\n      </div>\n    </div>\n  )\n}";
my $close_new = "          )\n        })}\n      </div>\n\n      <Pager {...pg} label=\"bridges\" />\n    </div>\n  )\n}";
$c = () = $s =~ /\Q$close_old\E/g; die "BR close anchor: found $c\n" unless $c==1;
$s =~ s/\Q$close_old\E/$close_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "bridge history: paginated (was capped at 8).\n";
PERL
perl "$PL3" "$BR"; rm -f "$PL3"

echo
echo "Verify:"
grep -n "usePaged\|<Pager" "$MT" "$HI" "$BR" | sed 's/^/  /'
echo
echo "Deploy (web only):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(ui): paginate history, my-trades, recent bridges' && git push"
