import type { ReactNode } from 'react'
import { explorerAddress } from '../config/chain'
import type { Deployment } from '../config/deployment'

function Node({ name, address, className = '', dashed, children }: { name: string; address: string; className?: string; dashed?: boolean; children: ReactNode }) {
  return (
    <div className={`arch-node ${className}`} data-dashed={dashed || undefined}>
      <a className="mono arch-name" href={explorerAddress(address)} target="_blank" rel="noreferrer">
        {name}
      </a>
      <p>{children}</p>
    </div>
  )
}

/** An arrow with the calls it carries. `across` points right beside the node it leaves, down on narrow screens. */
function Edge({ label, className = '', across }: { label: string; className?: string; across?: boolean }) {
  return (
    <div className={`arch-edge ${className}`} data-across={across || undefined}>
      <svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true">
        <path d="M14 2v23M9.5 20.5L14 26l4.5-5.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span className="mono">{label}</span>
    </div>
  )
}

/** The deployed contracts and the calls a transfer makes between them, as the gate's checks run. */
export function Architecture({ d }: { d: Deployment }) {
  return (
    <figure className="arch">
      <Node name="SecurityToken" address={d.token} className="arch-col">
        The ERC-20. Its <span className="mono">_update</span> runs checks 1 to 6 of the gate: the pause, each party's
        identity and freeze, and the free balance.
      </Node>
      <Edge across label="isVerified(to), isVerified(from)" />
      <Node name="IdentityRegistry" address={d.identityRegistry}>
        Who may hold: a verified flag, a KYC expiry, a country and an investor id for each wallet.
      </Node>
      <Edge className="arch-col" label="canTransfer(from, to, amount) before the move; transferred, created or destroyed after it" />
      <Node name="ModularCompliance" address={d.compliance} className="arch-col">
        The engine. Runs the rest of the gate: asks each module in registration order and stops at the first that refuses.
      </Node>
      <Edge className="arch-col" label="moduleCheck before the move; moduleTransferred, moduleCreated or moduleDestroyed after it" />
      <div className="arch-modules arch-wide">
        <Node name="MaxHoldersModule" address={d.maxHolders}>
          Keeps the holder count, from the token's balances after each move.
        </Node>
        <Node name="CountryRestrictionModule" address={d.countryRestriction}>
          Reads the recipient's country from the identity registry.
        </Node>
        <Node name="LockupModule" address={d.lockup}>
          Keeps each wallet's lockup clock, started by its first tokens.
        </Node>
        <Node name="DividendDistributor" address={d.distributor}>
          Never refuses: it watches each move to keep the income accounts.
        </Node>
      </div>
      <div className="arch-side arch-wide">
        <Node name="DocumentRegistry" address={d.documentRegistry}>
          Anchors the terms by the hash of their content. No transfer reads it.
        </Node>
        <Node name="TestnetDesk" address={d.desk} dashed>
          Testnet only. Holds the agent role on the registry and on the distributor and the issuer's role on the token, to
          verify wallets, mint tokens and pay coupons.
        </Node>
      </div>
      <figcaption className="hint arch-wide">
        The contracts on this deployment and the calls a transfer makes between them. Each name links to the contract on
        the block explorer.
      </figcaption>
    </figure>
  )
}
