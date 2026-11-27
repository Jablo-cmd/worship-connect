export type World = {
  runId: string
  orgA: string
  orgB: string
  /** membership ids by user name: { A, B } */
  mem: Record<string, { A?: string; B?: string }>
  ids: { campusN: string; campusS: string; ministryW: string; deptMusic: string; deptMedia: string; team1: string; team2: string; roleMember: string; roleAdmin: string; roleOwner: string; roleTeamLeader: string; roleDeptLeader: string; roleProdLead: string; roleWorshipDirector: string }
  tokens: { heidi: string; graceReinvite?: string }
}
declare module 'vitest' { export interface ProvidedContext { world: World } }
