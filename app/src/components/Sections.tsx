import type { ComponentProps } from 'react'
import { zeroAddress } from 'viem'
import { chain, explorerAddress, links } from '../config/chain'
import { navigate, pages, type Page } from '../hooks/useRoute'
import { formatDuration, formatEurc, formatNotes, shortAddress } from '../lib/format'
import type { TokenModel } from '../lib/model'
import { Mark } from './icons'
import { WalletButton } from './Wallet'

/** Link to a page of this app: a plain click switches page without a reload, a modified click keeps the browser's behavior. */
export function Link({ href, ...rest }: ComponentProps<'a'> & { href: string }) {
  return (
    <a
      href={href}
      {...rest}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(href)
      }}
    />
  )
}

export function Header({ page, onConnect, onDesk }: { page: Page; onConnect: () => void; onDesk: () => void }) {
  return (
    <header className="site-header">
      <div className="wrap">
        <Link className="wordmark" href="/">
          <Mark />
          Real Estate Note
        </Link>
        <span className="network">{chain.name}</span>
        <nav className="page-nav" aria-label="Pages">
          {pages.map((p) => (
            <Link key={p.page} className="page-link" href={p.path} aria-current={p.page === page ? 'page' : undefined}>
              {p.label}
            </Link>
          ))}
        </nav>
        <div className="header-actions">
          <button className="btn btn-faucet" onClick={onDesk} aria-label="Get test notes">
            <span>Test notes</span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 2.5c2 2.6 3.5 4.6 3.5 6.6a3.5 3.5 0 0 1-7 0c0-2 1.5-4 3.5-6.6z" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
          <WalletButton onConnect={onConnect} />
        </div>
      </div>
    </header>
  )
}

export function Notice() {
  return (
    <div className="notice">
      <div className="wrap">
        Testnet proof of concept for educational purposes, with tokens that have no value. Not audited. A testnet desk
        stands in for the KYC provider, the issuer and the paying agent: <Link href="/how-it-works#desk">how and why</Link>.
      </div>
    </div>
  )
}

export function HowItWorks({ model }: { model: TokenModel }) {
  const st = model.static
  const d = model.deployment
  const lockup = formatDuration(Number(model.live.lockupPeriod))
  return (
    <section className="section" id="how">
      <div className="wrap">
        <div className="section-head">
          <h2>How this token works</h2>
          <p>
            A plain ERC-20 asks one question: does the sender have the balance? This token asks whether this transfer,
            between these two wallets, is allowed right now. Each part is written up in the repository's guides.
          </p>
        </div>
        <div className="mechanics">
          <div className="mechanic" id="gate-order">
            <h3>One gate, in a fixed order</h3>
            <p>
              Every transfer goes through the token's <span className="mono">_update</span>, which checks, in order: the
              token is not paused, the recipient is verified and not frozen, the sender is verified, not frozen and holds
              enough unfrozen notes, and then each compliance module in the order the engine registered it. The first
              failure reverts the transfer. A mint runs the same checks on the recipient only. The public{' '}
              <span className="mono">canTransfer</span> runs the same function, so what the page reads cannot drift from
              what a transfer enforces.
            </p>
          </div>
          <div className="mechanic">
            <h3>Identity on both ends</h3>
            <p>
              A wallet must be verified to receive and to send. Verification is a record in the identity registry with an
              expiry, so a lapsed KYC stops a wallet just as a removed identity does. Removing an identity suspends the
              position without seizing it: the notes stay, and they cannot move until the wallet is verified again, the
              issuer burns them or a custodian recovers them.
            </p>
          </div>
          <div className="mechanic">
            <h3>Lockup from the first acquisition</h3>
            <p>
              The clock starts when a wallet goes from zero to a balance, by mint or by transfer, and later receipts never
              reset it, so nobody can lock your notes again by sending you dust. It clears when the wallet exits to zero.
              This deployment runs it for {lockup}; the production script sets 365 days.
            </p>
          </div>
          <div className="mechanic">
            <h3>Holders counted, never listed</h3>
            <p>
              The holder cap keeps a counter that the transfer hooks update from the balances after each move, so checking
              it costs the same at five holders as at five hundred. It only stops a transfer that would add a holder: an
              existing holder can always receive, and at the cap one holder can replace another.
            </p>
          </div>
          <div className="mechanic">
            <h3>Income by accumulator</h3>
            <p>
              A coupon raises one running total, dividends per share. A wallet's income is its balance times that total,
              less a correction that every transfer shifts equally and oppositely, so income earned before a sale stays
              with the seller. Each holder pulls its own claim, and a frozen or unverified wallet's income is withheld,
              still accruing, until that changes. <Link href="/dividends">See it live</Link>.
            </p>
          </div>
          <div className="mechanic">
            <h3>Operator powers, seen but not used here</h3>
            <p>
              The agent can pause the token, freeze a wallet or part of a balance and set the rule parameters. A custodian
              can move a lost wallet's whole balance to another verified wallet of the same investor, carrying any freeze
              across. On this deployment the deployer holds those roles: you see their effects on the seeded wallets, but
              no button on this page uses them.
            </p>
          </div>
        </div>

        <div className="oracle-note" id="desk">
          <div>
            <h3>What the testnet desk stands in for</h3>
            <p>
              On a real issuance a KYC provider verifies investors, the issuer sells the notes and a paying agent passes on
              the income. None of them can work on a public testnet, so a testnet-only contract,{' '}
              <a href={explorerAddress(d.desk)} target="_blank" rel="noreferrer">
                TestnetDesk
              </a>
              , stands in for all three. It holds one role for each and uses it only on the wallet that calls it, and it
              has no other function.
            </p>
            <p>
              Everything else is the repository's own contracts, unchanged. The lockup is shortened to {lockup} through its
              own setter and the holder cap stays at {model.live.maxHolders.toString()}, the production value. Someone with
              many addresses could fill the register; the agent can then raise the cap.
            </p>
            <p>
              The seeded wallets have addresses derived from a hash rather than from a key, so nobody can sign for them:
              each keeps the state it was seeded with and shows one outcome of the gate.
            </p>
          </div>
          <div className="flow" aria-label="The desk's three functions">
            <div className="flow-step">
              <b>1</b>
              <span>
                <strong>Verify.</strong> Writes your wallet to the identity registry with the country you declare, for{' '}
                {formatDuration(Number(st.kycValidity))}, through the agent role. It checks nothing else: not who you are,
                where you live or whether you are accredited. It records you as not accredited; no module reads that flag.
              </span>
            </div>
            <div className="flow-step">
              <b>2</b>
              <span>
                <strong>Get notes.</strong> Mints {formatNotes(st.notesPerClaim)} notes to your wallet once a day, through
                the issuer role. The mint goes through the full gate, so an unverified or restricted-country wallet is
                refused. Nothing is paid for them.
              </span>
            </div>
            <div className="flow-step">
              <b>3</b>
              <span>
                <strong>Pay a coupon.</strong> Mints {formatEurc(st.couponPerNote)} testnet EURC for each note outstanding
                and deposits it in the distributor, through the agent role there, at most once every{' '}
                {formatDuration(Number(st.couponInterval))}, whoever asks.
              </span>
            </div>
          </div>
        </div>

        <div className="oracle-note" id="attestations">
          <div>
            <h3>The other way in: signed attestations</h3>
            <p>
              The registry also accepts a record that anyone can submit, if it carries an EIP-712 signature from the claim
              signer. Trust then rests on the signature, not on whoever sends the transaction. The signed data binds the
              chain, the registry, an expiry and a nonce that every write to the wallet's record advances, so a signature
              cannot be used on another chain, after it expires, or after the agent has changed the record.
            </p>
            <p>
              {st.claimSigner === zeroAddress
                ? 'No claim signer is set on this deployment, so the path is closed here: it would need a signing key, and this site is static, with no server to keep one.'
                : `The claim signer on this deployment is ${shortAddress(st.claimSigner)}.`}
            </p>
          </div>
          <dl className="rows mono-rows">
            <div className="row">
              <dt>Domain separator</dt>
              <dd className="mono" title={st.domainSeparator}>
                {shortAddress(st.domainSeparator)}
              </dd>
            </div>
            <div className="row">
              <dt>Attestation type hash</dt>
              <dd className="mono" title={st.attestationTypehash}>
                {shortAddress(st.attestationTypehash)}
              </dd>
            </div>
            <div className="row">
              <dt>Claim signer</dt>
              <dd className="mono">{st.claimSigner === zeroAddress ? 'not set' : shortAddress(st.claimSigner)}</dd>
            </div>
          </dl>
        </div>
      </div>
    </section>
  )
}

export function Footer({ model }: { model: TokenModel | null }) {
  return (
    <footer className="site-footer">
      <div className="wrap">
        <p>Proof of concept, not audited, for educational purposes. Testnet tokens have no value.</p>
        <nav className="footer-links" aria-label="Links">
          <a href={links.repo} target="_blank" rel="noreferrer">
            Source code
          </a>
          <a href={links.docs} target="_blank" rel="noreferrer">
            Documentation
          </a>
          {model ? (
            <a href={explorerAddress(model.deployment.token)} target="_blank" rel="noreferrer">
              Token contract
            </a>
          ) : null}
          <a href={links.author} target="_blank" rel="noreferrer">
            Built by Gustavo Martín
          </a>
        </nav>
      </div>
    </footer>
  )
}
