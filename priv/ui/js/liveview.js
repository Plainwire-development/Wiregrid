export const WiregridHooks = {
  Composer: {
    mounted() {
      import("./composer.js").then(({ bindComposer }) => {
        this._wg = bindComposer(this.el, {
          onSubmit: (body) =>
            this.pushEvent(this.el.dataset.event || "wiregrid:send", { body }),
        });
      });
    },
    destroyed() {
      this._wg?.destroy?.();
    },
  },
  ChatActions: {
    mounted() {
      import("./chat.js").then(({ bindChatActions }) => {
        this._wgStop = bindChatActions(this.el, {
          action: (action, message) =>
            this.pushEvent("wiregrid:message_action", {
              action,
              id: message?.dataset.messageId,
            }),
          reaction: (reaction, message) =>
            this.pushEvent("wiregrid:reaction", {
              reaction,
              id: message?.dataset.messageId,
            }),
        });
      });
    },
    destroyed() {
      this._wgStop?.();
    },
  },
};
