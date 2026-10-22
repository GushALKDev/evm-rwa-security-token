import { Component, type ReactNode } from 'react'

/** Keeps a failure in one page from blanking the whole app: the header, the notice and the footer stay. */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey: string }, { error: Error | null }> {
  state: { error: Error | null } = { error: null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidUpdate(prev: { resetKey: string }) {
    // Moving to another page gives it a fresh start.
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null })
  }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <main className="wrap hero">
        <div className="callout" data-tone="danger" role="alert">
          This page could not be drawn from what the chain returned ({this.state.error.message}). Reload it to read the
          chain again.
        </div>
      </main>
    )
  }
}
