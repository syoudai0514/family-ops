import type {
  CompactScheduleEntry,
  LineCreationKind,
} from "./lineConversation.ts";

const GREEN = "#16815D";
const LINE_GREEN = "#06C755";
const TEXT = "#202124";
const MUTED = "#667085";
const BORDER = "#E5E7EB";

function actionButton(
  label: string,
  data: string,
  primary = false,
): Record<string, unknown> {
  const button: Record<string, unknown> = {
    type: "button",
    style: primary ? "primary" : "secondary",
    height: "sm",
    action: { type: "postback", label, data, displayText: label },
  };
  if (primary) button.color = LINE_GREEN;
  return button;
}
function messageButton(label: string, text: string): Record<string, unknown> {
  return {
    type: "button",
    style: "secondary",
    height: "sm",
    action: { type: "message", label, text },
  };
}
function row(label: string, value: string): Record<string, unknown> {
  return {
    type: "box",
    layout: "horizontal",
    spacing: "sm",
    paddingAll: "2px",
    contents: [
      { type: "text", text: label, size: "xs", color: MUTED, flex: 2 },
      {
        type: "text",
        text: value,
        size: "sm",
        color: TEXT,
        weight: "bold",
        wrap: true,
        flex: 5,
      },
    ],
  };
}

export function buildLineMenuFlex(appBaseUrl: string): Record<string, unknown> {
  const base = appBaseUrl.replace(/\/$/, "");
  return {
    type: "flex",
    altText: "おうちノートでできること",
    contents: {
      type: "bubble",
      size: "mega",
      header: {
        type: "box",
        layout: "vertical",
        paddingAll: "11px",
        backgroundColor: "#F2FBF7",
        contents: [
          {
            type: "text",
            text: "できること",
            size: "lg",
            weight: "bold",
            color: TEXT,
          },
          {
            type: "text",
            text: "文章でそのまま話しかけてOKです。",
            size: "xs",
            color: GREEN,
            margin: "xs",
            wrap: true,
          },
        ],
      },
      body: {
        type: "box",
        layout: "vertical",
        spacing: "xs",
        paddingAll: "9px",
        contents: [
          {
            type: "text",
            text: "予定を確認",
            weight: "bold",
            size: "xs",
            color: MUTED,
          },
          {
            type: "box",
            layout: "horizontal",
            spacing: "xs",
            contents: [
              messageButton("今日", "今日の予定は？"),
              messageButton("明日", "明日の予定教えて"),
              messageButton("今週", "今週の予定は？"),
            ],
          },
          { type: "separator", margin: "sm", color: BORDER },
          {
            type: "text",
            text: "追加・お願い",
            weight: "bold",
            size: "xs",
            color: MUTED,
            margin: "sm",
          },
          {
            type: "box",
            layout: "horizontal",
            spacing: "xs",
            contents: [
              messageButton("予定", "予定を追加したい"),
              messageButton("タスク", "タスクを追加したい"),
            ],
          },
          {
            type: "box",
            layout: "horizontal",
            spacing: "xs",
            contents: [
              messageButton("お願い", "お願いを送りたい"),
              messageButton("買い物", "買い物を追加したい"),
            ],
          },
          {
            type: "text",
            text: "例「明日の夜にゴミ出し」「牛乳を買い物に追加」",
            size: "xxs",
            color: MUTED,
            wrap: true,
            margin: "sm",
          },
        ],
      },
      footer: {
        type: "box",
        layout: "vertical",
        paddingAll: "4px",
        contents: [
          {
            type: "button",
            style: "link",
            height: "sm",
            color: GREEN,
            action: { type: "uri", label: "PWAを開く", uri: `${base}/today` },
          },
        ],
      },
    },
  };
}

export function buildIntentClarificationFlex(
  data: { pendingActionId: string; scheduleHint?: string | null },
): Record<string, unknown> {
  const id = data.pendingActionId;
  return {
    type: "flex",
    altText: "登録する種類を確認してください",
    contents: {
      type: "bubble",
      size: "mega",
      body: {
        type: "box",
        layout: "vertical",
        spacing: "xs",
        paddingAll: "11px",
        contents: [
          {
            type: "text",
            text: "どれとして登録しますか？",
            size: "lg",
            weight: "bold",
            color: TEXT,
          },
          ...(data.scheduleHint
            ? [{
              type: "text",
              text: `日時: ${data.scheduleHint}`,
              size: "xs",
              color: GREEN,
              wrap: true,
            }]
            : []),
          {
            type: "box",
            layout: "horizontal",
            spacing: "xs",
            contents: [
              actionButton(
                "予定",
                `action=clarify_kind&pending_action_id=${id}&kind=event`,
              ),
              actionButton(
                "タスク",
                `action=clarify_kind&pending_action_id=${id}&kind=task`,
              ),
            ],
          },
          {
            type: "box",
            layout: "horizontal",
            spacing: "xs",
            contents: [
              actionButton(
                "お願い",
                `action=clarify_kind&pending_action_id=${id}&kind=request`,
              ),
              actionButton(
                "買い物",
                `action=clarify_kind&pending_action_id=${id}&kind=shopping`,
              ),
            ],
          },
          {
            type: "text",
            text: "選んだあと、不足している内容だけ確認します。",
            size: "xxs",
            color: MUTED,
            wrap: true,
          },
        ],
      },
      footer: {
        type: "box",
        layout: "vertical",
        paddingAll: "4px",
        contents: [
          actionButton(
            "キャンセル",
            `action=cancel_pending&pending_action_id=${id}`,
          ),
        ],
      },
    },
  };
}

export function buildMissingTitleFlex(
  data: {
    pendingActionId: string;
    kind: LineCreationKind;
    scheduleLabel: string;
  },
): Record<string, unknown> {
  const kindLabel = data.kind === "event"
    ? "予定"
    : data.kind === "task"
    ? "タスク"
    : data.kind === "request"
    ? "お願い"
    : "買い物";
  return {
    type: "flex",
    altText: `あと1つ教えてください: ${kindLabel}`,
    contents: {
      type: "bubble",
      size: "mega",
      body: {
        type: "box",
        layout: "vertical",
        spacing: "xs",
        paddingAll: "11px",
        contents: [
          {
            type: "text",
            text: "あと1つ教えてください",
            size: "lg",
            weight: "bold",
            color: TEXT,
          },
          {
            type: "text",
            text: `「${kindLabel}」として進めます。`,
            size: "xs",
            color: GREEN,
          },
          row("日時", data.scheduleLabel),
          { type: "separator", margin: "xs", color: BORDER },
          {
            type: "text",
            text: data.kind === "shopping"
              ? "何を買いますか？"
              : data.kind === "request"
              ? "何をお願いしますか？"
              : "何を追加しますか？",
            size: "md",
            weight: "bold",
            color: TEXT,
            wrap: true,
          },
          {
            type: "text",
            text: "そのまま文章で返信してください。",
            size: "xxs",
            color: MUTED,
            wrap: true,
          },
        ],
      },
      footer: {
        type: "box",
        layout: "vertical",
        paddingAll: "4px",
        contents: [
          actionButton(
            "キャンセル",
            `action=cancel_pending&pending_action_id=${data.pendingActionId}`,
          ),
        ],
      },
    },
  };
}

export function buildScheduleSummaryFlex(
  title: string,
  entries: CompactScheduleEntry[],
  appBaseUrl: string,
): Record<string, unknown> {
  // Keep enough room for the navigation actions in iPhone LINE, including
  // while the software keyboard is visible. The PWA remains the full view.
  const shown = entries.slice(0, 6);
  const body: Record<string, unknown>[] = shown.map((entry) => {
    const time = entry.startsAt
      ? new Intl.DateTimeFormat("ja-JP", {
        timeZone: "Asia/Tokyo",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(new Date(entry.startsAt))
      : "終日";
    return row(
      time,
      `${entry.title}${entry.roleLabel ? ` ${entry.roleLabel}` : ""}${
        entry.conflict ? " ⚠️" : ""
      }`,
    );
  });
  if (entries.length > shown.length) {
    body.push({
      type: "text",
      text: `ほか${entries.length - shown.length}件`,
      size: "xxs",
      color: MUTED,
      align: "end",
    });
  }
  if (entries.length === 0) {
    body.push({
      type: "text",
      text: "予定はありません。",
      size: "sm",
      color: MUTED,
    });
  }
  return {
    type: "flex",
    altText: title,
    contents: {
      type: "bubble",
      size: "mega",
      header: {
        type: "box",
        layout: "vertical",
        paddingAll: "9px",
        backgroundColor: "#F2FBF7",
        contents: [{
          type: "text",
          text: `📅 ${title}`,
          size: "md",
          weight: "bold",
          color: TEXT,
        }],
      },
      body: {
        type: "box",
        layout: "vertical",
        spacing: "none",
        paddingAll: "8px",
        contents: body,
      },
      footer: {
        type: "box",
        layout: "horizontal",
        spacing: "xs",
        paddingAll: "4px",
        contents: [messageButton("明日", "明日の予定教えて"), {
          type: "button",
          style: "secondary",
          height: "sm",
          action: {
            type: "uri",
            label: "詳しく見る",
            uri: `${appBaseUrl.replace(/\/$/, "")}/week`,
          },
        }],
      },
    },
  };
}
