import { TopNav }      from '@/components/layout/TopNav'
import { Sidebar }     from '@/components/layout/Sidebar'
import { MobileNav }   from '@/components/layout/MobileNav'
import { ProfileGuard } from '@/components/profile/ProfileGuard'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen flex-col overflow-hidden bg-app-bg">
      <TopNav />
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar — hidden on mobile, visible md+ */}
        <Sidebar />
        {/* Main content */}
        <main className="flex-1 overflow-y-auto p-4 pb-24 md:p-6 md:pb-6">
          <ProfileGuard>{children}</ProfileGuard>
        </main>
      </div>
      {/* Bottom nav — mobile only */}
      <MobileNav />
    </div>
  )
}
