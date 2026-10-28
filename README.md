# Windsor-Essex Grocery Deals

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
