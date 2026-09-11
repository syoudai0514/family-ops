-- XC-03 follow-up: the LINE/PWA reproposal adapter is a service-only canonical
-- mutation entry point. It validates the authenticated production actor and
-- request ownership internally, then invokes private receipt/notification
-- primitives that are intentionally not executable by service_role directly.
-- Run the adapter with definer rights, matching the existing server_tx command
-- boundary pattern while retaining the function's empty search_path.

alter function public.server_tx_repropose_request_v1(
  uuid, uuid, uuid, bigint, timestamptz, text
) security definer;
