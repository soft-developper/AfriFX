import { redirect } from 'next/navigation'

/**
 * The wallet-connect entry point is gone (decision D2: hard cutover).
 * Accounts replaced it, and the wallet is created for the user after
 * they sign up rather than being something they bring.
 *
 * Kept as a redirect so old links, bookmarks and any in-app references
 * still land somewhere sensible instead of a 404.
 */
export default function ConnectPage() {
  redirect('/signin')
}
