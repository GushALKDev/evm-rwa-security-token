# Design notes

## Accent and data colors

Petrol is this app's accent in the demo family: the same OKLCH lightness and chroma as the reference's verdigris,
on another hue. It replaces verdigris wherever verdigris is the accent: `--accent`, `--accent-hover`,
`--accent-soft`, `--focus`, the primary buttons, the headline figure, the selected states, the success toast icon,
and the two mark bars that carried verdigris.

| Role | Light | Dark |
| :-- | :-- | :-- |
| Petrol accent | #2B6876 | #79B2C0 |
| Petrol hover | #1F545F | #90C2CE |
| Petrol soft | #DBE9ED | #1C343A |
| Text on the accent | #FFFFFF | #0E1412 |
| Mark tint (first bar) | #A4C7D0 | #4C7D88 |

No per-app data colors. The gate's outcomes use the accent for a check that passes, the family's danger red for
the check that stops a transfer, and the neutral ink for checks the contract never reaches. Each outcome is also
drawn (a tick, a cross, or the check's number) and written ("Passes", "Stops here", "Not reached"), so none of
them relies on color. The theme-color meta tags carry the ground color, as in the reference.

Everything else is the family system from the money market's app: the IBM Plex type, the neutral greys, the
danger and warn colors, spacing, radii and components.

## Subject

A permissioned security token for a real-estate-backed note, on a testnet. Visitors are protocol founders, CTOs
and engineers judging the engineering behind it, plus anyone who wants to try holding a regulated instrument. The
page has two jobs: let them onboard, receive and send tokens and claim income without friction, and make the
token's defining mechanic visible: a transfer is allowed only when identity, freeze state and every compliance
rule agree, in a fixed order.

## The one memorable element

The transfer gate, drawn as the sequence the contract runs: the pause, the recipient's identity and freeze, the
sender's identity, freeze and unfrozen balance, then each compliance module in the order the engine registered it.
Pick a sender, a recipient and an amount, and every check lights up from live state, up to the one that stops the
transfer, with the revert the token would raise. Checks after it read "Not reached", because the contract never
evaluates them. Each check names the contract that runs it and links to that line of its source, at the commit the
deployment was built from. Under the checks, the token's own `canTransfer` answers for the same inputs, so the drawing
is cross-checked against the contract while it is read.

The seeded wallets exist for this drawing. Between them, and with the visitor's own wallet, they reach every check
except the pause and the holder cap, which depend on the agent and on the register rather than on a wallet: the
unverified and lapsed wallets stop at verification, the frozen holder at the freeze, the partly frozen one at the free
balance, the investor in Iran at the jurisdiction rule, and a wallet in its first five minutes at the lockup.
Above the inputs, one chip per seeded wallet sets the pair and the amount that show its outcome, and says what the
wallet was seeded with; a chip lights up whenever the inputs match it, however they were set. Everything else on the
page stays quiet.

## Layout

```
header        wordmark (links to the token page), network, pages, test tokens, wallet
              pages: Token, Dividends, How it works, on a second header row below 1024 px
notice        one line: testnet, for educational purposes, not audited, what the desk stands in for

/             hero: headline, the gate (with the send action when the sender is you), four figures
              grid: your position (left, wider) | the rule set and the anchored terms (right)
/dividends    coupons (figures, pay the next one) | income of your wallet or a seeded one (claim your own, and the
              formula with that wallet's numbers)
/how-it-works six mechanics, then the desk note and the attestation note

footer
```

Each page has its own path, so a link can point straight at the dividends or at the desk note
(`/how-it-works#desk`).

Left-aligned throughout. Two columns from 1024 px, one below. The gate's inputs go from three columns to two
below 1024 px and to one below 720 px, where a passing check keeps its glyph and its word moves to screen readers
only.

## Rules

- Copy names what the user does: Verify, Get tokens, Send, Pay the coupon, Claim. The button that says Send
  produces a toast that says Tokens sent. Under each of them, one line names the call it sends and the calls the
  desk makes in turn, with the amounts in base units.
- Every preview shows before and after, computed with the contract's own rules and rounding: tokens, holders,
  lockup clocks and unclaimed income for a transfer; the deposit, the per-token total and your share for a coupon.
- Rules that depend on time (the lockup, KYC expiry, the desk's cooldowns) are evaluated at the latest block's
  timestamp, which is what the call's simulation sees; the visitor's clock only drives countdowns.
- Errors say what happened and what to do, decoded from the custom errors of every contract the call reaches.
- Motion only where something changed: none in this app beyond the toasts. Reduced motion is respected.
