#lang racket/base

;; AI provider presets. BYOK only — no built-in keys, no hosted proxy.
;; Keys live in a 0600 settings file in the app data dir, are held by the
;; Racket backend, and never enter the webview (the UI sees the masked
;; sentinel __SAVED__ after a save; see ai.rkt).

(provide provider-presets
         default-preset-id)

(struct preset (id          ; stable id used by settings
                label       ; display name (bilingual rendering is UI work)
                model       ; default model
                base-url    ; empty = provider default
                kind        ; "openai" | "anthropic" | "ollama"
                env-key)    ; env var consulted when no key is configured
  #:transparent)

(define (p id label model base-url kind [env-key #f])
  (preset id label model base-url kind env-key))

;; Mirrors the family BYOK preset table (HackDigest / Booklight): the
;; Chinese providers stay first-class alongside OpenAI/Anthropic; Ollama
;; is keyless-local.
(define provider-presets
  (list
   (p "glm"        "GLM (Zhipu)"        "glm-4.7"        "https://open.bigmodel.cn/api/paas/v4"  "openai")
   (p "glm-coding" "GLM Coding"         "glm-4.7"        "https://open.bigmodel.cn/api/paas/v4"  "openai")
   (p "deepseek"   "DeepSeek"           "deepseek-chat"  "https://api.deepseek.com/v1"           "openai" "DEEPSEEK_API_KEY")
   (p "qwen"       "Qwen (DashScope)"   "qwen-max"       "https://dashscope.aliyuncs.com/compatible-mode/v1" "openai")
   (p "kimi"       "Kimi (Moonshot)"    "kimi-k2"        "https://api.moonshot.cn/v1"            "openai" "MOONSHOT_API_KEY")
   (p "doubao"     "Doubao (Volcengine)" "doubao-seed-1.6" "https://ark.cn-beijing.volces.com/api/v3" "openai")
   (p "siliconflow" "SiliconFlow"       "deepseek-ai/DeepSeek-V3" "https://api.siliconflow.cn/v1" "openai")
   (p "openai"     "OpenAI"             "gpt-5-mini"     ""                                      "openai" "OPENAI_API_KEY")
   (p "anthropic"  "Anthropic"          "claude-haiku-4-5" ""                                    "anthropic" "ANTHROPIC_API_KEY")
   (p "ollama"     "Ollama (local)"     "qwen3:8b"       "http://localhost:11434/v1"             "ollama")))

(define (find-preset id)
  (findf (lambda (x) (string=? (preset-id x) id)) provider-presets))

(define default-preset-id "deepseek")

(provide (struct-out preset)
         find-preset)
