import { useEffect, useState } from 'react'
import { useBytecode } from 'wagmi'
import { DeskDialog } from './components/DeskDialog'
import { DividendsPage } from './components/Dividends'
import { ErrorBoundary } from './components/ErrorBoundary'
import { Hero } from './components/Hero'
import { PositionCard } from './components/Position'
import { RuleSetCard, TermsCard } from './components/RuleSet'
import { Footer, Header, HowItWorks, Notice } from './components/Sections'
import { Toasts } from './components/Toasts'
import { ConnectDialog } from './components/Wallet'
import { chain, deployment, links } from './config/chain'
import { useModel } from './hooks/useModel'
import { scrollToTarget, useRoute } from './hooks/useRoute'

function NotDeployed() {
  return (
    <main className="wrap hero">
      <div className="hero-head">
        <h1>The token is not deployed on {chain.name} yet.</h1>
        <p className="hero-sub">
          Run the testnet deployment script to create it; it writes the addresses this app reads. Until then, the{' '}
          <a href={links.repo}>source code</a> is the place to look.
        </p>
      </div>
    </main>
  )
}

function Token() {
  const { model, error } = useModel()
  // forge writes the deployment file while it simulates, before anything is sent, so a broadcast that fails after
  // that leaves a file naming contracts with no code. Say so, rather than blaming the RPC.
  const code = useBytecode({ address: deployment!.token, query: { staleTime: Infinity } })
  const noCode = code.isSuccess && (!code.data || code.data === '0x')
  const { page, url } = useRoute()
  // A fragment's target only exists once the page has rendered, so a direct link waits for the first read. How it
  // works renders without it.
  const ready = model !== null || page === 'how'
  useEffect(scrollToTarget, [url, ready])
  const [connectOpen, setConnectOpen] = useState(false)
  const [deskOpen, setDeskOpen] = useState(false)
  const openConnect = () => {
    setDeskOpen(false)
    setConnectOpen(true)
  }
  const openDesk = () => setDeskOpen(true)

  const problem = noCode ? (
    <div className="callout" data-tone="warn" role="alert">
      The deployment file names a token with no code on {chain.name}, so the deployment it describes never landed. Run
      the testnet deployment again; it rewrites the file.
    </div>
  ) : error ? (
    <div className="callout" data-tone="warn" role="alert">
      The token could not be read from {chain.name}. The RPC may be rate limiting requests; the page retries on its own.
    </div>
  ) : null

  return (
    <>
      <Header page={page} onConnect={openConnect} onDesk={openDesk} />
      <Notice />
      {page === 'how' ? (
        // Mostly prose about the contracts: it does not wait for the chain, and fills in live figures as they arrive.
        <ErrorBoundary resetKey={page}>
          <main>
            {!model && problem ? <div className="wrap section-problem">{problem}</div> : null}
            <HowItWorks model={model} />
          </main>
        </ErrorBoundary>
      ) : model ? (
        <ErrorBoundary resetKey={page}>
          <main>
            {page === 'token' ? (
              <>
                <Hero model={model} onConnect={openConnect} onDesk={openDesk} />
                <div className="wrap main-grid">
                  <div className="stack">
                    <PositionCard model={model} onConnect={openConnect} onDesk={openDesk} />
                  </div>
                  <div className="stack">
                    <RuleSetCard model={model} />
                    <TermsCard model={model} />
                  </div>
                </div>
              </>
            ) : null}
            {page === 'dividends' ? <DividendsPage model={model} onConnect={openConnect} /> : null}
          </main>
        </ErrorBoundary>
      ) : (
        <main className="wrap hero">{problem ?? <p className="muted">Reading the token from {chain.name}…</p>}</main>
      )}
      <Footer model={model} />
      {connectOpen ? <ConnectDialog onClose={() => setConnectOpen(false)} /> : null}
      {deskOpen && model ? <DeskDialog model={model} onClose={() => setDeskOpen(false)} onConnect={openConnect} /> : null}
      <Toasts />
    </>
  )
}

export function App() {
  return deployment ? <Token /> : <NotDeployed />
}
