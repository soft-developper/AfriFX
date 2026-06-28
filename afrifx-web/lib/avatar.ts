// Deterministic avatar color from username
const COLORS = [
  '#378ADD','#10B981','#8B5CF6','#F59E0B',
  '#EF4444','#EC4899','#14B8A6','#F97316',
  '#06B6D4','#84CC16','#A855F7','#FB923C',
]

export function getAvatarColor(seed: string): string {
  let hash = 0
  for (let i = 0; i < seed.length; i++) {
    hash = seed.charCodeAt(i) + ((hash << 5) - hash)
  }
  return COLORS[Math.abs(hash) % COLORS.length]
}

export function getInitials(name: string): string {
  const parts = name.trim().split(/\s+/)
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase()
  return name.slice(0, 2).toUpperCase()
}
