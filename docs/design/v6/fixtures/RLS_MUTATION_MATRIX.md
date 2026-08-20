# Mutation Authorization Matrix — v6

| mutation | caller | allowed | key checks |
|---|---|---:|---|
| create task | HH adult | yes | assignee same HH; operation receipt |
| edit task | HH adult | yes | active task, same HH |
| complete task self | HH adult | yes | same HH, state valid |
| mark partner handled | HH adult | yes | partner resolved server-side, not arbitrary id |
| reassign once | HH adult | yes | new assignee same HH |
| send request | requester HH adult | yes | recipient same HH and != caller |
| accept request | recipient only | yes | pending, row lock |
| decline request | recipient only | yes | pending |
| cancel request | requester only | yes | pending only |
| shopping transition | HH adult | yes | valid state transition |
| create handover | HH adult | yes | shared text only; raw private |
| mark handover read | self | yes | user derived from auth |
| mark notification read | recipient only | yes | recipient=self |
| change recurrence | HH adult | yes | assignee same HH, exclusion valid |
| update routine schedule | HH adult | yes | valid kind/time/weekday |
| routine checkin complete | session HH adult | yes | actor semantics server-side |
| create calendar event | HH adult | yes | busy member ids derived from self/partner/family selection |
| classify calendar busy | HH adult | yes | selected users same HH |
| direct tx RPC from authenticated client | any | **no** | execute grant revoked |
| cross-HH actor/resource spoof | any | **no** | Edge derives HH + DB FK |

## v6 additions
- configure-evening-routines: JWT Edge only
- busy classification mutations: Edge/service-only
- line quota reservations: private/service-role only
