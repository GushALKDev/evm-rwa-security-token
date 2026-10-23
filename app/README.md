# Real Estate Note demo app

A web app for the permissioned security token in this repository, running on Base Sepolia with testnet tokens.
Without a wallet, visitors can walk every check of the transfer gate on a set of seeded wallets. With one, they
can verify their wallet at a testnet desk, receive tokens, send them through the gate, pay a coupon and claim
their share of it.

Proof of concept, not audited, for educational purposes. The tokens are testnet stand-ins with no value.

Live: https://rwa-poc.gushalk.workers.dev

## What it shows

- **The transfer gate.** Pick a sender, a recipient and an amount, and the page draws every check in the order
  the contract runs it: the pause, the recipient's identity and freeze, the sender's identity, freeze and
  unfrozen balance, then each compliance module in the engine's registration order. It stops where the contract
  stops and names the revert the token would raise. The rules are mirrored in `src/lib/gate.ts`, and the token's
  own `canTransfer` is read for the same inputs and shown alongside. Each check links to the line of the contract
  that runs it, at the commit the deployment was built from (`src/config/source.ts`).
- **Seeded wallets, one per outcome.** A settled holder, a partly frozen one, a frozen one, a suspended one, an
  investor in a restricted country, a wallet never registered and one whose attestation lapses an hour after
  deployment. One chip per wallet sets the pair and the amount that show its outcome (`src/lib/scenarios.ts`).
- **Previews before every call.** A transfer shows both balances, the holder count, the lockup clocks it starts
  or clears and the seller's unclaimed income before and after; a coupon shows the deposit and your exact share.
  Each call is simulated before the wallet asks for a signature, so a revert arrives as a sentence
  (`src/lib/errors.ts`) instead of a failed transaction.
- **Income by accumulator.** The dividends page shows what a token has been paid since issuance, what the
  distributor holds unclaimed, and the formula behind a wallet's figure with its own values, including the
  correction the contract keeps in storage. It works for your wallet or any seeded one, so the formula and a
  withheld income can be seen without connecting.
- **The anchored terms.** The page fetches the published terms document and hashes it in the browser, to compare
  with the hash the document registry anchored.

Everything the app computes (the gate, the holder count and lockup clocks a transfer leaves, the accumulator, the
coupon and each holder's share) follows the contracts' order, scales and rounding, and is checked to the wei
against a local deployment (`scripts/parity.test.ts`).

## The testnet stand-ins

On a real issuance a KYC provider verifies investors, the issuer sells the tokens and a paying agent passes on the
income. None of them can work on a public testnet, so [`TestnetDesk`](../script/testnet/TestnetDesk.sol), a
testnet-only contract, stands in for all three. It holds one role for each:

- `onboard(country)` writes the caller, never another address, to the identity registry for 30 days, through the
  agent role. It checks only that the country code is between 1 and 999, the range of ISO 3166-1 numeric codes. It
  does not check who the caller is, where they live or whether they are accredited, and it records them as not
  accredited (no module reads that flag). Like any agent write it replaces the whole record, so it also undoes an
  agent's removal of the caller and resets a custom investor id to the default one.
- `claimTokens()` mints 10 tokens to the caller, and only the caller, once a day, through the issuer role (the only
  role that can mint).
  The mint runs the token's full gate, so an unverified, frozen or restricted-country wallet is refused. Nothing
  is paid for the tokens.
- `payCoupon()` mints 5 testnet EURC for each token outstanding and deposits it in the distributor for every holder,
  through the agent role there, at most once every 10 minutes, whoever calls it.

Its only other functions are its owner's: `setDistributor`, which wires the distributor once and checks its
currency and token, and Ownable's ownership transfer and renouncement. None of them uses the desk's roles.

[`TestnetEURC`](../script/testnet/TestnetEURC.sol) is the settlement currency, 6 decimals like Circle's EURC,
mintable only by the desk. Circle's own EURC exists on Base Sepolia, but Circle's faucet hands it out in small,
rate-limited amounts, too little for coupons sized like a note's.

Everything else is the repository's own contracts, deployed by `script/Deploy.s.sol`'s own code with its
parameters, and every role stays with the deploying key. Three settings are made on top, through the contracts'
own functions: the dividend distributor is attached, North Korea and Iran are restricted (the two jurisdictions
the FATF calls on its members to apply countermeasures to), and the lockup is shortened from 365 days to 5 minutes
with the module's `setLockupPeriod`, so a visitor can see it lift. The holder cap stays at 499. One person with
many addresses could fill it at two transactions per address; the agent then reopens the register with
`setMaxHolders`.

The seeded wallets have addresses derived from a hash rather than from a key, so nobody can sign for them: they
never send, and only the agent can change their identity or freeze state. Anyone can still send them tokens, and the
lapsed one was written to lapse an hour after deployment.

## Run it locally

Requires Node 22 and, for a local chain, Foundry.

```bash
cd app
npm install
npm run dev                  # reads the Base Sepolia deployment
```

Against a local chain instead (anvil and a full, seeded deployment):

```bash
./app/scripts/local-chain.sh                 # from the repo root; writes src/config/deployments/31337.json
cd app && VITE_CHAIN_ID=31337 npm run dev
```

The script starts anvil on port 8545 when nothing answers there. To use another port, start anvil yourself and
pass the URL to both: `RPC=http://127.0.0.1:8555 ./app/scripts/local-chain.sh`, then
`VITE_CHAIN_ID=31337 VITE_RPC_URL=http://127.0.0.1:8555 npm run dev`.

Checks:

```bash
npm run typecheck
npm test                                                   # the mirrored rules and math, and the source links
LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts     # parity against a local deployment
```

The parity suite runs the gate for every combination of sender, recipient and amount it builds from the seeded
wallets and three visitors, and compares it with `canTransfer`, every module's `moduleCheck` and the revert the
token raises, before and after the lockups run out and while the token is paused, and checks that each of the
gate's cases stops at the check it is there to show. It checks the lockup one second either side of the unlock, the
holder count and clocks each kind of transfer leaves, a coupon's amount, accumulator, remainder and every holder's
share, the corrections a transfer and a mint write, and a claim. It also replays the case the gas margin exists for.
A second suite, `scripts/tx.test.ts`, runs the app's write path (`src/lib/tx.ts`): it refuses to send while the
wallet is on another network (a second anvil stands for it), and reports a transaction that lands and reverts, one
the wallet cancels, and one whose receipt never comes as what they are. Both suites revert the chain to a snapshot
when they finish, so they can run again, and run one after the other since they share the chain. CI runs them on
every push, against a fresh local deployment.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address with a little Base Sepolia ETH from one of the
[Base faucets](https://docs.base.org/get-started/get-funds), then:

```bash
forge script script/testnet/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

The script simulates the whole run first, including a check of every seeded outcome through the token's own
`canTransfer` and the modules' `moduleCheck`, and only then broadcasts. It deploys the seven contracts of
`script/Deploy.s.sol` with the same parameters, the dividend distributor, the desk and its currency, grants the
desk its three roles, shortens the lockup, restricts the two jurisdictions, seeds the wallets and pays the first
coupon. Every role stays with the deploying key, and the desk receives its roles only after the seeding, so a
stranger watching the broadcast can race nothing but the first coupon. If the run's last transaction, that coupon,
reverts with `CouponTooSoon`, someone paid it first through the desk and the deployment is complete.

On a broadcast it writes `app/src/config/deployments/84532.json`, which the app reads: commit that file. A run
without `--broadcast` leaves the file alone. forge writes the file while it simulates, before anything is sent, so
if the broadcast then fails the file names contracts that never landed: do not commit it, and run the script
again. The app says so too if it is served such a file.

Nothing in the deployment depends on an external feed or a short time window, so there is no second script.

To verify the contracts on BaseScan, add `--verify --etherscan-api-key <key>` (an Etherscan API V2 key covers
BaseScan).

The testnet tooling has its own tests, kept apart so the protocol's test figures stay unchanged:

```bash
FOUNDRY_PROFILE=testnet forge test
```

## Deploy the app to Cloudflare Workers

The app runs as `rwa-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at
`dist/` and holds the SPA fallback, which serves `index.html` for every page path (`/dividends`,
`/how-it-works`). `public/_headers` holds the cache and security headers; Vite copies it into `dist/`.

The `og:image` and `og:url` tags in `index.html` carry the absolute workers.dev URL, since link preview crawlers
do not resolve relative paths: change them if the app moves to its own domain or another account subdomain.

First deploy, from a terminal in `app/`:

```bash
npx wrangler login           # authorizes wrangler on your Cloudflare account, in the browser
npm run deploy               # builds, deploys and prints the workers.dev URL
```

Deploys on push: in the Cloudflare dashboard, connect this repository to the Worker (Workers Builds) with root
directory `app`, build command `npm run build` and deploy command `npx wrangler deploy`. The Worker name in
`wrangler.jsonc` must match the Worker in the dashboard, or the build fails.

`VITE_RPC_URL` is optional, for when the public Base Sepolia RPC rate limits the page. Vite reads it at build time,
so on Workers Builds it goes in the build variables (Settings, Build), not in the runtime variables. Any key in it
is visible to visitors, so restrict it to the site's domain at the provider.

The Workers Free plan is enough: the site is static, there is no Worker script, and requests to static assets are
free.

## Structure

```
src/
  abi/          generated from the Foundry build (npm run abi after forge build)
  config/       chain, links, and the deployment files written by the script
  lib/          the gate and accumulator mirrors, gas margin, error messages, countries, formatting
  hooks/        chain reads, the derived model, transactions, toasts, the current page
  components/   the interface
scripts/
  local-chain.sh     local rehearsal of the testnet deployment
  parity.test.ts     app rules and math against a local deployment
  source.test.ts     every source link against the contracts at the commit it pins (needs the git history)
  sync-abi.mjs       regenerates src/abi
```

Design notes, shared with the other demo apps: [DESIGN.md](./DESIGN.md).
