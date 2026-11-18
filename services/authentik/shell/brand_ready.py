# Runs inside the authentik container via `ak shell -c`.
# Exit 0 once the default brand (created by a blueprint) exists.
from authentik.brands.models import Brand

raise SystemExit(0 if Brand.objects.filter(default=True).exists() else 1)
