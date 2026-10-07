import type { SupabaseClient } from "@supabase/supabase-js";

export type LivePosition = { lat: number; lng: number };

export type FeedComment = {
  id: string;
  report_id: string;
  author_id: string;
  author_name: string | null;
  body: string;
  created_at: string;
  is_street_resident: boolean;
};

export type FeedVerification = {
  report_id: string;
  user_id: string;
  user_name: string | null;
  created_at: string;
  is_street_resident: boolean;
};

/**
 * Best-effort live GPS read. Resolves to null if unsupported, denied or timed
 * out; the server then falls back to the user's registered home location.
 */
export function getLivePosition(timeoutMs = 8000): Promise<LivePosition | null> {
  if (typeof navigator === "undefined" || !navigator.geolocation) {
    return Promise.resolve(null);
  }
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30_000 }
    );
  });
}

/** Post a comment. The server decides whether it gets the street-resident badge. */
export async function addComment(
  supabase: SupabaseClient,
  reportId: string,
  body: string,
  position?: LivePosition | null
) {
  const { data, error } = await supabase.rpc("add_comment", {
    p_report_id: reportId,
    p_body: body,
    p_lat: position?.lat ?? null,
    p_lng: position?.lng ?? null,
  });
  if (error) throw error;
  return data;
}

/** Verify a report. A duplicate verification rejects with code "23505". */
export async function verifyReport(
  supabase: SupabaseClient,
  reportId: string,
  position?: LivePosition | null
) {
  const { data, error } = await supabase.rpc("verify_report", {
    p_report_id: reportId,
    p_lat: position?.lat ?? null,
    p_lng: position?.lng ?? null,
  });
  if (error) throw error;
  return data;
}

/** Comments in chronological order, each with its badge flag. */
export async function fetchComments(
  supabase: SupabaseClient,
  reportId: string
): Promise<FeedComment[]> {
  const { data, error } = await supabase
    .from("comments_feed")
    .select("*")
    .eq("report_id", reportId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as FeedComment[];
}

/** Verifiers of a report, each with their badge flag. */
export async function fetchVerifications(
  supabase: SupabaseClient,
  reportId: string
): Promise<FeedVerification[]> {
  const { data, error } = await supabase
    .from("verifications_feed")
    .select("*")
    .eq("report_id", reportId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as FeedVerification[];
}
