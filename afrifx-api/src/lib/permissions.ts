// All available admin permissions.
//
// NOTE: some capabilities are deliberately NOT permissions, because they are
// SUPER-ADMIN ONLY and must never be delegable:
//   * Maintenance mode (taking the platform or a section offline) — too
//     dangerous to grant; the super admin alone controls it.
export const PERMISSIONS = {
  VIEW_DASHBOARD:    'view_dashboard',
  MANAGE_OFFERS:     'manage_offers',     // force release / cancel offers
  RESOLVE_DISPUTES:  'resolve_disputes',  // settle disputes
  MANAGE_USERS:      'manage_users',      // edit user profiles, warnings
  SUSPEND_USERS:     'suspend_users',     // suspend user accounts
  VIEW_ANALYTICS:    'view_analytics',    // platform analytics
  MANAGE_TREASURY:   'manage_treasury',   // platform treasury / fees
  MANAGE_ADMINS:     'manage_admins',     // add/remove/edit sub-admins
  MANAGE_CONTENT:    'manage_content',    // edit About / Contact page content
  VIEW_MESSAGES:     'view_messages',     // read contact-form submissions
  VIEW_AUDIT_LOG:    'view_audit_log',    // see audit trail
  SEND_BROADCASTS:   'send_broadcasts',   // email sub-admins / users
} as const

export type Permission = typeof PERMISSIONS[keyof typeof PERMISSIONS]

export const ALL_PERMISSIONS = Object.values(PERMISSIONS)

// Human-readable labels + descriptions for the UI
export const PERMISSION_META: Record<string, { label: string; description: string; note?: string }> = {
  view_dashboard:   { label: 'View Dashboard',    description: 'Access the admin overview and stats' },
  manage_offers:    { label: 'Manage Offers',     description: 'Force release or cancel P2P offers' },
  resolve_disputes: { label: 'Resolve Disputes',  description: 'Settle disputes — release or refund USDC' },
  manage_users:     { label: 'Manage Users',      description: 'Edit profiles, issue warnings' },
  suspend_users:    { label: 'Suspend Users',     description: 'Suspend or ban user accounts' },
  view_analytics:   { label: 'View Analytics',    description: 'See platform-wide analytics and charts' },
  manage_treasury:  {
    label: 'Manage Treasury',
    description: 'View and manage platform fees',
    note: 'Not active yet — the treasury dashboard ships with the mainnet contract.',
  },
  manage_admins:    { label: 'Manage Admins',     description: 'Add, edit, suspend sub-admins; set their duty hours' },
  manage_content:   { label: 'Manage Content',    description: 'Edit the About and Contact pages' },
  view_messages:    { label: 'View Messages',     description: 'Read contact-form submissions' },
  view_audit_log:   { label: 'View Audit Log',    description: 'Review all admin activity and duty sessions' },
  send_broadcasts:  { label: 'Send Broadcasts',   description: 'Email sub-admins and registered users' },
}
