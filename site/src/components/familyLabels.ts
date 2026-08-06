// Display names for experimental feature families.
//
// Shared so the catalogue and the feature-page header cannot disagree. They did:
// PageTitle derived the label by title-casing the slug, which turned
// `worlds-tasks` into "Worlds Tasks" while the catalogue rendered "Worlds &
// tasks" from this map. Slugs are not display names -- keep the mapping here.
export const familyLabels: Record<string, string> = {
  reservoirs: 'Reservoirs',
  embodiment: 'Embodiment',
  'worlds-tasks': 'Worlds & tasks',
  collectives: 'Collectives',
  analyses: 'Analyses',
  evolution: 'Evolution',
};
