export type Theme = "dark" | "light" | string;
export type Density = "compact" | "comfortable" | "cozy" | string;
export interface Reaction { emoji: string; count: number; mine?: boolean; }
export interface Message { id: string | number; author?: string; body?: string; time?: string; avatarUrl?: string; compact?: boolean; reply?: { id?: string | number; author?: string; body?: string }; reactions?: Reaction[]; }
export interface ChatHandlers { reaction?: (reaction: string, message: Element | null, event: Event) => void; action?: (action: string, message: Element | null, event: Event) => void; }
export declare const version: string;
export declare function createStore<T>(initial?: T): { get(): T; set(next: T | ((state: T) => T)): T; patch(partial: Partial<T>): T; subscribe(fn: (state: T) => void): () => void };
export declare function setTheme(theme: Theme, root?: HTMLElement): void;
export declare function restoreTheme(root?: HTMLElement, fallback?: Theme): Theme;
export declare function setDensity(density: Density, root?: HTMLElement): void;
export declare function renderMessage(message: Message, options?: {actions?: false | string[]}): HTMLElement;
export declare function appendMessage(container: Element, message: Message, options?: {maxMessages?: number}): HTMLElement;
export declare function upsertMessage(container: Element, message: Message, options?: {maxMessages?: number}): HTMLElement;
export declare function reconcileOptimistic(container: Element, nonce: string, message: Message, options?: {maxMessages?: number}): HTMLElement;
export declare function trimTimeline(container: Element, maxMessages?: number): void;
export declare function jumpToMessage(root: Element, messageId: string | number, duration?: number): boolean;
export declare function bindChatActions(root: Element, handlers?: ChatHandlers): () => void;
export declare function bindComposer(form: HTMLFormElement, options?: {maxBytes?: number; maxHeight?: number; enterToSend?: boolean; onSubmit?: (body: string, context: unknown) => unknown | Promise<unknown>}): {submit(): Promise<void>; destroy(): void};
export declare function createOverlay(panel: HTMLElement, options?: {escape?: boolean; onClose?: () => void}): {open(): void; close(): void; destroy(): void};
export declare function bindTabs(root: Element): () => void;
export declare const WiregridHooks: Record<string, object>;
