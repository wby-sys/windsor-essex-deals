# Windsor-Essex Grocery Deals

**Public page:** https://wby-sys.github.io/windsor-essex-deals/ (no login needed; anyone with the link can open it)

It updates by itself every Thursday and Saturday around 8–9 AM Windsor time, even when your PC is off. GitHub Actions runs `app/Get-Deals.ps1` on GitHub's computers (see `.github/workflows/deals.yml`), saves `data/history.csv` back to this repository so price trends keep building, and publishes the page with GitHub Pages. To refresh it by hand, open the repository's **Actions** tab, choose **Update grocery deals** and click **Run workflow**.

**Location and map:** tap the location button (pin icon) to enter any postal code or use your device's location, and pick a range from 5 to 40 km. Picks, search and flyers then only include stores with a location in range, and show how far each one is. **Store map** shows every store in range. Store locations come from OpenStreetMap (`data/stores.json`; `storeMatch` in config.json links them to flyer stores). The OpenStreetMap servers don't answer GitHub's computers, so the cloud runs use the saved list. To refresh it, run `app\Get-Deals.ps1` on a PC, then commit and push `data/stores.json`. Postal codes are looked up with Esri's public geocoder, with OpenStreetMap and geocoder.ca as backups. Deals are only gathered for the Windsor-Essex `areas` in config.json.

To change settings (watchlist, products, memberships), edit `config.json` on GitHub, or locally and then `git pull` and `git push`. The next run uses the new settings.

- **latest-deals.html**: open this. It opens on **Top Picks**: the 3 best-value deals for each kind of product, aisle by aisle, with meat and produce first. Flyers, search, favourites and a shopping list are there too.
- **share/windsor-essex-deals.html**: a copy you can share. It's built by `app\Build-Share.ps1` from latest-deals.html, with small copies of the pictures built in (hosted pages can't load pictures from other websites). It's published at https://claude.ai/artifact/B25cQ7XWsA44m3FwPXtxg9 and doesn't update by itself: rebuild it and ask Claude to republish it after new flyers come out.
- **run-now.cmd**: double-click to refresh now and open the app.
- **config.json**: your settings.
  - `watchlist`: products you buy often. They're starred under "My list".
  - `picks`: the Top Picks sections in order (Protein, Vegetables, Fruits, Everything else). Each section has groups (Chicken, Beef, Pork, Eggs...), and each group lists the products that get top-3 picks. An item can say `"aisle"` to match a different store aisle, for example salmon in Seafood.
  - `aislePriority`: how search results and the aisle list are ranked.
  - `myMemberships`: loyalty programs you belong to, for example `["PC Optimum", "Scene+", "moi"]`. Member-only prices from programs not listed here are never used as Top Picks; they show a red "members only" label everywhere else. `membershipStores` lists stores you can't shop at without a membership (Costco).
  - `maxPickPrice`: packages over this price (for example a $145 case of wings) are only picked when nothing smaller is on sale.
  - `areas` and extra stores.
  - Any term can be plain, like `"cottage cheese"`, or `{ "term": "...", "exclude": ["..."] }` to filter out wrong matches.
- **data/history.csv**: every flyer item seen so far. The price history and trend badges come from this file, so don't delete it.
- **data/run.log**: a log of each run.
- **reports/**: a dated copy of each report.
- **app/Get-Deals.ps1**: downloads the flyers and builds the report.
- **app/template.html**: the app's look and behaviour. The script fills in the data.

The app runs automatically every Thursday and Saturday at 8 AM through Windows Task Scheduler (task name "Windsor-Essex Grocery Deals"). If the PC is off at that time, it runs the next time the PC is on.

Your favourites, shopping list and chosen area are saved in the browser you open the app in.

Search tips: `"greek yogurt"` matches the exact phrase, `cheese -cream` leaves out a word, and `chick*` matches the start of a word.

To rebuild the app after editing config.json or template.html, without downloading again:

```
powershell -NoProfile -File app\Get-Deals.ps1 -ReportOnly -Open
```
