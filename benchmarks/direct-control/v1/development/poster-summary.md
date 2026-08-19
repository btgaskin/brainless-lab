# Direct-control development summary for poster use

These are development-selection summaries from 16 independent blocks per selected
model-task cell. They are not confirmation results. The same blocks were used to choose
the input gain, so the intervals below are descriptive and must not be presented as
held-out evidence.

## Selected-cell profile

| Task | Model | Gain | Mean | SD | 95% interval | Formal outcome mean |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Tracking | Falandays | 1 | 55.75° error | 16.14° | 47.15–64.35° | `track_score = 0.473` |
| Tracking | SORN | 4 | 38.86° error | 24.64° | 25.73–51.99° | `track_score = 0.713` |
| Pong | Falandays | 1 | 4.000 returns | 1.826 | 3.027–4.973 | `hit_rate = 0.483` |
| Pong | SORN | 32 | 5.125 returns | 2.941 | 3.558–6.692 | `hit_rate = 0.613` |
| Plank CartPole Easy | Falandays | 8 | 24.25 steps | 13.59 | 17.01–31.49 | `fitness = 24.25` |
| Plank CartPole Easy | SORN | 8 | 15.13 steps | 16.93 | 6.11–24.14 | `fitness = 15.13` |

For orientation, a uniformly random circular heading has an expected absolute error of
90°. Both selected Tracking cells improve on that reference, but their residual heading
error remains large.

## Paired development contrasts

Differences are SORN minus Falandays. Negative is favourable only for Tracking; positive
is favourable for Pong and CartPole.

| Task | Mean difference | SD | 95% interval |
| --- | ---: | ---: | ---: |
| Tracking | −16.89° | 36.32° | −36.24–2.46° |
| Pong | +1.125 returns | 2.895 | −0.418–2.668 |
| Plank CartPole Easy | −9.125 steps | 20.235 | −19.905–1.655 |

All three profile-coordinate intervals include zero. No inferential claim should be made
from these selected development cells. The untouched 32-block confirmation is still
pending human-reviewed execution.

## Resource context

Both profiles use 200 dynamic nodes. Falandays has 200 excitatory and no inhibitory nodes;
SORN has 167 excitatory and 33 inhibitory nodes. SORN's dense excitatory-inhibitory paths
produce about 12,685–12,705 recurrent edges in these selected cells, compared with about
3,973–3,997 for Falandays. The benchmark therefore compares complete declared profiles at
equal dynamic-node count, not equal synapse count or isolated neuron rules.

Exact values, normalised outcomes, termination fractions, and mean edge counts are in
[`poster-model-statistics.csv`](poster-model-statistics.csv). Exact paired contrasts are in
[`poster-paired-contrasts.csv`](poster-paired-contrasts.csv). The six full gain tables and
their clean-run provenance are alongside this file.

Intervals use the two-sided Student *t* method implemented by the benchmark, with the
randomised block as the inferential unit.
