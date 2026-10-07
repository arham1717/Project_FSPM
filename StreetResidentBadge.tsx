"use client";

import { useCallback, useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  addComment,
  fetchComments,
  getLivePosition,
  type FeedComment,
} from "@/lib/streetVerification";

/** "Verified Street Resident" badge. Renders nothing when not verified. */
export function StreetResidentBadge({ verified }: { verified: boolean }) {
  if (!verified) return null;
  return (
    <span
      className="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-800"
      title="This neighbor lives on the same street as this report"
    >
      <svg aria-hidden="true" viewBox="0 0 20 20" className="h-3 w-3 fill-current">
        <path d="M10 1.5l2.4 1.7 2.9.1.9 2.8 2.3 1.8-.9 2.8.9 2.8-2.3 1.8-.9 2.8-2.9.1L10 20l-2.4-1.7-2.9-.1-.9-2.8L1.5 13.6l.9-2.8-.9-2.8 2.3-1.8.9-2.8 2.9-.1L10 1.5zm-1.2 11.3l4.6-4.6-1.1-1.1-3.5 3.5-1.5-1.5-1.1 1.1 2.6 2.6z" />
      </svg>
      Verified Street Resident
    </span>
  );
}

/** Comment thread with badges and a comment box (US-04 + US-06). */
export function CommentThread({
  supabase,
  reportId,
}: {
  supabase: SupabaseClient;
  reportId: string;
}) {
  const [comments, setComments] = useState<FeedComment[]>([]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setComments(await fetchComments(supabase, reportId));
    } catch (e) {
      setError((e as Error).message);
    }
  }, [supabase, reportId]);

  useEffect(() => {
    load();
  }, [load]);

  async function submit() {
    if (!text.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const position = await getLivePosition(); // null => server uses home location
      await addComment(supabase, reportId, text.trim(), position);
      setText("");
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-4">
      <ul className="space-y-3">
        {comments.map((c) => (
          <li key={c.id} className="rounded-lg border border-gray-200 p-3">
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-medium">{c.author_name ?? "Neighbor"}</span>
              <StreetResidentBadge verified={c.is_street_resident} />
              <time className="ml-auto text-xs text-gray-500" dateTime={c.created_at}>
                {new Date(c.created_at).toLocaleString()}
              </time>
            </div>
            <p className="mt-1 whitespace-pre-wrap text-sm">{c.body}</p>
          </li>
        ))}
      </ul>

      <div className="flex flex-col gap-2 sm:flex-row">
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          maxLength={2000}
          rows={2}
          placeholder="Add a comment…"
          className="w-full rounded-lg border border-gray-300 p-2 text-sm"
        />
        <button
          onClick={submit}
          disabled={busy || !text.trim()}
          className="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
        >
          {busy ? "Posting…" : "Comment"}
        </button>
      </div>
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
    </section>
  );
}
