'use client'
import { useSectionDown, useMaintenance, MaintenanceGate } from '@/hooks/useMaintenance'

/*
  Wrap a feature page. If its section (or the whole platform) is under
  maintenance, the user sees the maintenance state INSTEAD of the feature —
  so they can't start something that the API would reject anyway.

  Admins aren't gated in the app UI; the API lets them through, and they use
  the admin panel to verify an upgrade.
*/
export function SectionGuard({
  section, children,
}: { section: string; children: React.ReactNode }) {
  const down = useSectionDown(section)
  const { data } = useMaintenance()

  if (down) {
    return <MaintenanceGate down={down} defaultMessage={data?.defaultMessage} />
  }
  return <>{children}</>
}
