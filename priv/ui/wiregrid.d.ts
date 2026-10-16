export type Theme = "dark" | "light" | string;
export type Density = "compact" | "comfortable" | "cozy" | string;
export interface Reaction { emoji: string; count: number; mine?: boolean; }
export interface Message { id: string | number; nonce?: string; author?: string; body?: string; time?: string; avatarUrl?: string; compact?: boolean; reply?: { id?: string | number; author?: string; body?: string }; reactions?: Reaction[]; }
export interface MessageOptions { actions?: false | string[]; maxMessages?: number; }
export interface ComposerContext { form: HTMLFormElement; textarea: HTMLTextAreaElement; }
export interface ComposerOptions { maxBytes?: number; maxHeight?: number; enterToSend?: boolean; onSubmit?: (body: string, context: ComposerContext) => unknown | Promise<unknown>; onError?: (error: unknown, context: ComposerContext) => void; }
export interface Composer { submit(): Promise<boolean | void>; destroy(): void; }
export interface TimelineOptions extends MessageOptions { autoScroll?: boolean; }
export interface Timeline { readonly size: number; append(message: Message): HTMLElement; upsert(message: Message): HTMLElement; get(id: string | number): HTMLElement | null; remove(id: string | number): boolean; clear(): void; destroy(): void; }
export interface ReadyMessage { type: "ready"; session_id: string; resume_token?: string; restored: Record<string, unknown>; }
export interface ChatEnvelope { type: "event"; topic: string; delivery_id: string; event_id?: string | null; class: "durable" | "ephemeral"; event: Record<string, unknown>; }
export interface ChatResponse { type: "response"; id: number; ok: boolean; value?: unknown; events?: Array<{ id: string; event: Record<string, unknown>; inserted_at_ms: number; meta: Record<string, unknown> }>; cursor?: string | null; pong?: string | number; }
export interface ClientOptions {
  maxPending?: number; requestTimeoutMs?: number; connectTimeoutMs?: number; maxBufferedBytes?: number;
  onReady?: (message: ReadyMessage) => unknown;
  onEvent?: (message: ChatEnvelope) => unknown;
  onClose?: (event: CloseEvent) => unknown;
  onError?: (error: unknown) => unknown;
  onDebug?: (event: { event: string; op?: string; pending: number }) => unknown;
}
export interface ChatClient {
  readonly ready: Promise<ReadyMessage>; readonly pendingRequests: number;
  subscribe(topic: string): Promise<ChatResponse>; unsubscribe(topic: string): Promise<ChatResponse>;
  say(topic: string, body: string, extra?: Record<string, unknown>): Promise<ChatResponse>;
  publish(topic: string, event: Record<string, unknown>, options?: { class?: "durable" | "ephemeral"; persist?: boolean }): Promise<ChatResponse>;
  history(topic: string, cursor?: string | null, limit?: number): Promise<ChatResponse>;
  ack(deliveryId: string): Promise<ChatResponse>; presence(status: string): Promise<ChatResponse>;
  joinRoom(room: string): Promise<ChatResponse>; leaveRoom(room: string): Promise<ChatResponse>;
  ping(nonce?: string | number): Promise<ChatResponse>; close(): void;
}
export interface MountChatOptions extends ClientOptions, TimelineOptions {
  url: string | URL; topic: string; label?: string; placeholder?: string; composerLabel?: string; sendLabel?: string;
  maxBytes?: number; enterToSend?: boolean;
  mapMessage?: (envelope: ChatEnvelope) => Message | null;
}
export interface ChatHandlers { reaction?: (reaction: string, message: Element | null, event: Event) => void; action?: (action: string, message: Element | null, event: Event) => void; }
export declare const version: string;
export declare function createStore<T>(initial?: T): { get(): T; set(next: T | ((state: T) => T)): T; patch(partial: Partial<T>): T; subscribe(fn: (state: T) => void): () => void };
export declare function setTheme(theme: Theme, root?: HTMLElement): void;
export declare function restoreTheme(root?: HTMLElement, fallback?: Theme): Theme;
export declare function setDensity(density: Density, root?: HTMLElement): void;
export declare function renderMessage(message: Message, options?: {actions?: false | string[]}): HTMLElement;
export declare function appendMessage(container: Element, message: Message, options?: MessageOptions): HTMLElement;
export declare function upsertMessage(container: Element, message: Message, options?: MessageOptions): HTMLElement;
export declare function reconcileOptimistic(container: Element, nonce: string, message: Message, options?: MessageOptions): HTMLElement;
export declare function trimTimeline(container: Element, maxMessages?: number): void;
export declare function jumpToMessage(root: Element, messageId: string | number, duration?: number): boolean;
export declare function bindChatActions(root: Element, handlers?: ChatHandlers): () => void;
export declare function bindComposer(form: HTMLFormElement, options?: ComposerOptions): Composer;
export { bindComposer as mountComposer };
export declare function createOverlay(panel: HTMLElement, options?: {escape?: boolean; onClose?: () => void}): {open(): void; close(): void; destroy(): void};
export declare function bindTabs(root: Element): () => void;
export declare const WiregridHooks: Record<string, object>;
export declare function createTimeline(container: HTMLElement, options?: TimelineOptions): Timeline;
export declare function connectChat(url: string | URL, options?: ClientOptions): ChatClient;
export declare function mountChat(root: HTMLElement, options: MountChatOptions): { client: ChatClient; timeline: Timeline; composer: Composer; ready: Promise<ReadyMessage | void>; destroy(): void };
export declare function qs(root: ParentNode | null, selector: string): Element | null;
export declare function qsa(root: ParentNode | null, selector: string): Element[];
export declare function text(tag: string, value: unknown, className?: string): HTMLElement;
export declare function uid(prefix?: string): string;
export declare function clamp(value: number, min: number, max: number): number;

declare const wiregrid: {
  version: typeof version; createStore: typeof createStore; setTheme: typeof setTheme;
  restoreTheme: typeof restoreTheme; setDensity: typeof setDensity;
  appendMessage: typeof appendMessage; upsertMessage: typeof upsertMessage;
  bindChatActions: typeof bindChatActions; renderMessage: typeof renderMessage;
  jumpToMessage: typeof jumpToMessage; bindComposer: typeof bindComposer; mountComposer: typeof bindComposer;
  createOverlay: typeof createOverlay; bindTabs: typeof bindTabs; WiregridHooks: typeof WiregridHooks;
  connectChat: typeof connectChat; createTimeline: typeof createTimeline; mountChat: typeof mountChat;
};
export default wiregrid;
