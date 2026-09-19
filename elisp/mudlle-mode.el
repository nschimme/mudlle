;; mudlle code editing commands for Emacs
;; Copyright (mudlle) 1985, 1986, 1987 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 1, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.

(when (< emacs-major-version 24)
  (error "Emacs 24 is required by mudlle-mode.el"))

(unless (require 'cl-lib nil t)
  ;; cl-lib was added in 24.3; emulate it
  (require 'cl)
  (defalias 'cl-case 'case)
  (defalias 'cl-destructuring-bind 'destructuring-bind)
  (defalias 'cl-loop 'loop))

(require 'eldoc)
(require 'font-lock)
(require 'help-mode)
(require 'newcomment)
(require 'rx)
(eval-and-compile
  (require 'dabbrev))

(defvar mudlle-mode-abbrev-table nil
  "Abbrev table in use in mudlle-mode buffers.")
(define-abbrev-table 'mudlle-mode-abbrev-table ())

(defvar mudlle-mode-map ()
  "Keymap used in mudlle mode.")
(unless mudlle-mode-map
  (setq mudlle-mode-map (make-sparse-keymap))
  (define-key mudlle-mode-map "["        'electric-mudlle-brace)
  (define-key mudlle-mode-map "]"        'electric-mudlle-brace)
  (define-key mudlle-mode-map ";"        'electric-mudlle-semi)
  (define-key mudlle-mode-map "\M-\C-q"  'indent-mudlle-exp)
  (define-key mudlle-mode-map "\177"     'backward-delete-char-untabify)
  (define-key mudlle-mode-map "\C-c\C-c" 'comment-region)
  (define-key mudlle-mode-map "\t"       'mudlle-indent-command)
  (define-key mudlle-mode-map "\M-\t"    'mudlle-complete-symbol)
  (define-key mudlle-mode-map "\C-c\C-h" 'mudlle-help)
  (define-key mudlle-mode-map "\C-c\C-a" 'mudlle-apropos))

(defvar mudlle-apropos-mode-map nil "Keymap for mudlle-apropos-mode.")
(unless mudlle-apropos-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r"          'mudlle-apropos-follow)
    (define-key map "q"           'quit-window)
    (define-key map " "           'scroll-up)
    (define-key map "\177"        'scroll-down)
    (define-key map "a"           'mudlle-apropos)
    (define-key map "n"           'mudlle-apropos-next)
    (define-key map "p"           'mudlle-apropos-previous)
    (define-key map "\t"          'mudlle-apropos-next)
    (define-key map "\e\t"        'mudlle-apropos-previous)
    (define-key map [(shift tab)] 'mudlle-apropos-previous)
    (define-key map [backtab]     'mudlle-apropos-previous)
    (setq mudlle-apropos-mode-map map)))

(defvar mudlle-mode-syntax-table nil
  "Syntax table in use in mudlle-mode buffers.")

(defvar-local mudlle-ftaf-current nil)

(if mudlle-mode-syntax-table
    ()
  (setq mudlle-mode-syntax-table (make-syntax-table))
  (modify-syntax-entry ?\\ "\\" mudlle-mode-syntax-table)
  (modify-syntax-entry ?\" "_" mudlle-mode-syntax-table)
  (modify-syntax-entry ?/ ". 124b" mudlle-mode-syntax-table)
  (modify-syntax-entry ?\n "> b" mudlle-mode-syntax-table)
  (modify-syntax-entry ?\r "> b" mudlle-mode-syntax-table)
  (modify-syntax-entry ?* ". 23n" mudlle-mode-syntax-table)
  (modify-syntax-entry ?_ "_" mudlle-mode-syntax-table)
  (modify-syntax-entry ?! "_" mudlle-mode-syntax-table)
  (modify-syntax-entry ?? "_" mudlle-mode-syntax-table)
  (modify-syntax-entry ?# "_" mudlle-mode-syntax-table)
  (modify-syntax-entry ?+ "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?- "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?= "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?% "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?< "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?> "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?& "." mudlle-mode-syntax-table)
  (modify-syntax-entry ?| "." mudlle-mode-syntax-table))

(eval-when-compile
  (require 'align))

(eval-after-load 'align
  (lambda ()
    (add-to-list 'align-rules-list
                 `(mudlle-comment
                   (regexp   . "\\(\\s-*\\)\\(//.*\\|/\\*.*\\*/\\s-*\\)$")
                   (modes    . (quote (mudlle-mode)))
                   (column   . comment-column)
                   (valid    . ,(function
		                 (lambda ()
		                   (save-excursion
		                     (goto-char (match-beginning 1))
		                     (not (bolp))))))))
    (let ((ops (regexp-opt '("=>" "."
                             "=" "+=" "-=" "*=" "/=" "%="
                             "^=" "&=" "|=" "&&=" "^^="
                             "||=" ">>=" "<<="))))
      (add-to-list 'align-rules-list
                   `(mudlle-pattern-match
                     (regexp . ,(concat "\\(\\s-+\\)" ops))
                     (modes  . (quote (mudlle-mode))))))))

(defconst mudlle-type-names
  '("icode"  "closure"     "variable"   "internal"  "primitive"  "varargs"
    "secure" "integer"     "string"     "vector"    "pair"       "symbol"
    "table"  "private"     "object"     "character" "gone"       "oport"
    "mcode"  "float"       "bigint"     "null"      "connection" "cookie"
    "file"   "weak_ref"    "regexp"     "none"      "any"        "function"
    "list"   "bigint_like" "float_like" "false"     "int")
  "The allowed names of mudlle data types.")

(defconst mudlle-type-names-regexp
  (concat "\\<" (regexp-opt mudlle-type-names) "\\>")
  "Regular expression matching a mudlle type name.
Does not contains any submatch groups.")

(defconst mudlle-typeset-regexp
  (concat "\\(?:" mudlle-type-names-regexp
          "\\|\\(?:{\\s-*"
          mudlle-type-names-regexp
          "\\(?:\\s-*,\\s-*" mudlle-type-names-regexp "\\)*"
          "\\s-*}\\)\\)")
  "Regular expression matching a mudlle typeset.
Does not contain any submatch groups.")

(defconst mudlle-symbol-regexp "\\<[a-zA-Z][a-zA-Z0-9$_:?!]*"
  "Regular expression with no submatches matching a mudlle symbol.")

(defconst mudlle-anchored-symbol-regexp (concat "\\=" mudlle-symbol-regexp)
  "Regular expression with no submatches matching a mudlle symbol at point.")

(eval-and-compile
  (defconst mudlle-character-constant-regexp
    (rx not-word-boundary "?"
        (or (: "\\" (or (: "N{" (+ (any "A-Z" ?- ?\ )) "}")
                        (: "x" (= 2 (any "0-9" "A-F" "a-f")))
                        (: (** 1 3 (any "0-7")))
                        anything))
            (not (any "(){}[]\"\t\n\v\f\r "))))
    "Regular expression matching a mudlle character constant."))

(eval-and-compile
  (defconst mudlle-max-raw-string-hashes
    256
    "Max number of #-characters that that be used in a mudlle raw
string delimeter.")

  (defconst mudlle-partial-string-regexp
    (let ((raw-hashes (format "#\\{0,%d\\}" mudlle-max-raw-string-hashes)))
      (rx (or (: (group-n 2 "\"\"\"")     ; triple-quoted
	         (group-n 3 (? (or (1+ (not (in "\\\"")))
		                   (: ?\\ anything))
		               (0+
		                (0+ (not (in "\\\"")))
		                (? ?\\ anything)
		                (? ?\" (? ?\")
		                   (or (1+ (not (in "\\\"")))
			               (: ?\\ anything)))
		                )))
	         (? (group-n 1 "\"\"\"")))
              ;; raw string
              (: (group-n 2 ?r (group-n 4 (regexp raw-hashes)) ?\")
                 (group-n 3 (minimal-match (0+ anything)))
                 (or (group-n 1 (: ?\" (backref 4)))
                     string-end))
              ;; single-quoted
	      (: (group-n 2 ?\")
	         (group-n 3 (0+ (or (1+ (not (in "\"\\\n")))
		                    (: ?\\ anything))))
	         (? (group-n 1 ?\")))
	      )))
    "Regular expression matching a possibly partial mudlle string.
The first submatch group, if present, contains any closing delimeter.
The second submatch group contains the opening delimeter.
The third submatch group contains the content string."))

(defconst mudlle-anchored-partial-string-regexp
  (rx-to-string `(: point (regexp ,mudlle-partial-string-regexp)))
  "Regular expression matching a possibly partial mudlle string starting at
point.
The first submatch group, if present, contains any last closing quote.")

(defun mudlle-string-syntax-propertize ()
  "Put the `syntax-table' and `syntax-multiline' properties on a mudlle string
as matched by `mudlle-partial-string-regexp'."
  (let ((beg         (match-beginning 0))
        (end         (match-end 0))
        (end-quote   (match-end 1))
        (payload-beg (match-beginning 3))
        (payload-end (match-end 3)))

    (if (nth 4 (syntax-ppss beg))
        ;; inside comment
        (while (progn (forward-char 1)
                      (eq (char-after) ?\")))
      (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "|"))
      (when (and payload-beg (eq (char-after beg) ?r))
        ;; backslashes in raw string are not escapes
        (goto-char payload-beg)
        (while (re-search-forward "[\\\\\"]+" payload-end t)
          (put-text-property (match-beginning 0) (match-end 0) 'syntax-table
                             (string-to-syntax "_"))))
      (goto-char end)
      (when (< beg (line-beginning-position))
        (put-text-property beg end 'syntax-multiline t))
      (when end-quote
        (put-text-property (1- end-quote) end-quote
                           'syntax-table (string-to-syntax "|"))))))

(defconst mudlle-syntax-propertize-function
  (syntax-propertize-rules
   (mudlle-character-constant-regexp
    (0 (ignore)))
   (mudlle-partial-string-regexp
    (0 (ignore (mudlle-string-syntax-propertize))))))

(defconst mudlle-anchored-formal-argument-regexp
  (concat "\\="
          "\\(" mudlle-typeset-regexp "[[:space:]\n]*\\)?"
	  "\\(" mudlle-symbol-regexp "\\)")
  "Regular expression matching a mudlle formal argument.
The first submatch group, if present, contains the data typeset.
The second submatch group contains the name of the argument.")

(eval-and-compile
  (defconst mudlle-help-markup-regexp "`\\(.[a-zA-Z0-9_$?!]*\\)"
    "Regular expression used to find text to be marked up using
`mudlle-help-highlight-face'. Only subexpression 1 will be
retained in the final text."))

(defconst mudlle-end-of-line-regexp
  "\\s-*\\(/\\*\\([^*]*\\|\\*[^/]\\)*\\*/\\s-*\\)*\\(//.*\\)?$"
  "Regular expression matching optional comments and then end of line.")

(defun mudlle-forward-expr (limit)
  "Move point past one mudlle expression, at most until LIMIT."
  (save-restriction
    (narrow-to-region (point-min) limit)
    (condition-case nil
        (while (progn
                 (mudlle-skip-comment limit)
                 (if (looking-at "[,;]")
                     nil
		   (let ((old-point (point)))
                     (forward-sexp)
		     (> (point) old-point)))))
      (:success (< (point) limit))
      (scan-error nil))))

(defun mudlle-skip-comment (limit)
  "Move point past all comments, at most until LIMIT."
  (save-restriction
    (narrow-to-region (point-min) limit)
    (while (forward-comment 1)))
  (< (point) limit))

(defun mudlle-fontify-typeset (subexp)
  "Fontifies the typeset in the region matched by SUBEXP in the last search,
typically for `mudlle-typeset-regexp'."
  (when (match-beginning subexp)
    (save-excursion
      (save-match-data
        (goto-char (match-beginning subexp))
        (let ((limit (match-end subexp)))
          (while (re-search-forward mudlle-type-names-regexp limit t)
            (font-lock-apply-highlight
             '(0 font-lock-type-face nil t))))))))

(defun mudlle-fontify-complex-argument (limit)
  "Fontifies one complex argument component starting at point, until LIMIT."
  (mudlle-skip-comment limit)
  (cond ((re-search-forward "\\=,\\s-*" limit t)
         (cond ((looking-at "(")
                (forward-sexp)
                t)
               ((re-search-forward mudlle-anchored-symbol-regexp limit t)
                t)))
        ((looking-at "_")
         (when (< (point) limit)
           (forward-char))
         t)
        ((looking-at "[[({]")
         (let ((end (save-excursion (forward-sexp) (point))))
           (when (<= end limit)
             (forward-char)
             (setq end (1- end))
             (while (< (point) end)
               (mudlle-fontify-complex-argument end))
             (when (= (point) end)
               (forward-char)
               t))))
        ((re-search-forward "\\=<" limit t)
         (and (mudlle-fontify-complex-argument limit)
              (mudlle-skip-comment limit)
              (re-search-forward "\\=\\s-*=\\s-*" limit t)
              (mudlle-fontify-complex-argument limit)
              (mudlle-skip-comment limit)
              (re-search-forward "\\=>" limit t)))
        ((re-search-forward mudlle-anchored-symbol-regexp limit t)
	 (font-lock-apply-highlight
	  '(0 font-lock-variable-name-face))
         t)
        ((re-search-forward mudlle-anchored-partial-string-regexp limit t)
         (match-beginning 1))
        ((re-search-forward "\\=\\S-+" limit t))))

(defun mudlle-extract-strings-at-point ()
  "Deletes the mudlle string, or sequence of concatenated strings, at point.
and returns them as (list STRING MODE OPEN-DELIM END-DELIM).
Leaves point at the beginning of the first string."
  (let ((parse-state (parse-partial-sexp (save-excursion
                                           (mudlle-beginning-of-defun)
                                           (point))
                                         (point)))
        dst strings last last-word)
    (undo-boundary)
    (if (nth 3 parse-state)
        ;; beginning of string
        (goto-char (nth 8 parse-state))
      (re-search-forward "\\=\\s-*" nil t))

    (setq dst (point))
    (cl-loop while (re-search-forward
                    mudlle-anchored-partial-string-regexp nil t)
             do (setq last (match-end 0))
             unless (match-beginning 1) do (error "No string at point") end
             collect
             (let* ((this (match-string-no-properties 3))
                    (open-delim (or (match-string-no-properties 2)
                                    (error "Internal error")))
                    (end-delim  (or (match-string-no-properties 1)
                                    (error "Internal error")))
                    (mode (cond ((string-equal "\"" open-delim) :single)
                                ((string-equal "\"\"\"" open-delim) :triple)
                                ((string-match "\\`r#*\"\\'" open-delim) :raw)
                                (t (error "Internal error")))))
               (mudlle-skip-comment (point-max))
               (list this mode open-delim end-delim))
             until (not (when (eq (char-after) ?+)
                          (forward-char)
                          (mudlle-skip-comment (point-max))
                          t))
             finally do
             (unless last
               (error "No string at point"))
             (mudlle-skip-comment (point-max))
             (delete-region dst last)
             (goto-char dst))))

(defun mudlle-string-to-triple-quote ()
  "Convert the string at point to a canonical triple-quoted string."
  (interactive)
  (let ((orig-pos (point))
        (strings  (mudlle-extract-strings-at-point))
        (dst      (point))
        last-word)
    (setq orig-pos (- orig-pos (point)))

    (insert "\"\"\"")
    (cl-destructuring-bind (str mode open-delim end-delim)
        (car strings)
      (setq orig-pos (max 0 (- orig-pos (length open-delim))))
      ;; retain any leading backslash-newline
      (when (string-match "\\`\\\\\n" str)
        (insert "\\\n")))

    (setq last-word (point))
    (cl-loop
     for (this mode open-delim close-delim) in strings do
     (cl-loop
      with next-nquote = 2
      with nquote = nil
      for i from 0 to (1- (length this)) do
      (when (and last-word (>= (current-column) 79))
        (let ((p (set-marker (make-marker) (point))))
          (goto-char last-word)
          (insert "\\\n")
          (goto-char p)
          (set-marker p nil)
          (setq last-word nil
                next-nquote 0)))

      (setq nquote next-nquote
            next-nquote 0)

      ;; not perfect but will land us close enough
      (when (>= i orig-pos)
        (setq dst      (point-marker)
              orig-pos most-positive-fixnum))

      (let ((c (elt this i)) n)
        (if (and (not (eq c ?\")) (eq mode :raw))
            (insert
             (cl-case c
               (?\a "\\a")
               (?\b "\\b")
               (?\f "\\f")
               (?\n c)
               (?\r "\\r")
               (?\t "\\t")
               (?\v "\\v")
               (?\\ "\\\\")
               (t (if (string-equal (get-char-code-property
                                     c 'general-category)
                                    "Cc")
                      (format "\\%03o" c)
                    c))))
          (cl-case c
            (?\  (setq last-word (point))
                 (while (progn (insert ?\ )
                               (and (< (1+ i) (length this))
                                    (= (elt this (1+ i)) ?\ )))
                   (setq i (1+ i))))
            (?\\ (cl-case (setq n (elt this (1+ i)))
                   (?\n (setq i (1+ i)))
                   (?n (setq i (1+ i))
                       (insert ?\n))
                   (?N (when (string-match "\\\\N\\(?:{[^}]*}\\)?" this i)
                         (insert (match-string 0 this))
                         (setq i (1- (match-end 0)))))
                   (?\" (setq next-nquote nquote))
                   (t (insert c n)
                      (setq i (1+ i)))))
            (?\" (setq next-nquote (1+ nquote))
                 (when (or (= nquote 2)
                           (= (1+ i) (length this)))
                   (insert ?\\)
                   (setq next-nquote 0))
                 (insert ?\"))
            (t (insert c)))))))

    (when (> (current-column) 76)
      (unless last-word
        (setq last-word (point)))
      (let ((p (set-marker (make-marker) (point))))
        (goto-char last-word)
        (insert "\\\n")
        (goto-char p)
        (set-marker p nil)))

    (insert "\"\"\"")
    (goto-char dst)))

(defun mudlle-string-to-raw ()
  "Convert the string at point to a raw string."
  (interactive)
  (let* ((orig-pos (point))
         (strings  (mudlle-extract-strings-at-point))
         (dst      (point))
         (hashes   0))
    (setq orig-pos (- orig-pos (point)))

    (cl-destructuring-bind (str mode open-delim end-delim)
        (car strings)
      (setq orig-pos (max 0 (- orig-pos (length open-delim)))))

    (let ((pos  0)
          (text (apply #'concat (mapcar #'car strings))))
      (while (string-match "\"#*" text pos)
        (setq pos (match-end 0))
        (let ((len (- pos (match-beginning 0))))
          (when (> len hashes)
            (setq hashes len)))))

    (when (> hashes 256)
      (error "String cannot be represented as a raw string"))

    (insert ?r)
    (insert-char ?\# hashes)
    (insert ?\")

    (cl-loop
     for (this mode open-delim close-delim) in strings do
     (if (eq mode :raw)
         (progn
           (when (<= orig-pos (length this))
             (setq dst      (+ (point) orig-pos)
                   orig-pos most-positive-fixnum))
           (insert this))

       (cl-loop
        for i from 0 to (1- (length this)) do

        ;; not perfect but will land us close enough
        (when (>= i orig-pos)
          (setq dst      (point-marker)
                orig-pos most-positive-fixnum))

        (let ((c (elt this i)))
          (if (not (eq c ?\\))
              (insert c)
            (let ((n (elt this (setq i (1+ i)))))
              (cl-case n
                (?\n)                ; do nothing
                (?a (insert "\a"))
                (?b (insert "\b"))
                (?f (insert "\f"))
                (?n (insert "\n"))
                (?r (insert "\r"))
                (?t (insert "\t"))
                (?v (insert "\v"))
                (?\\ (insert "\\"))
                (?\" (insert "\""))
                (?x (if (and (eq (string-match "x\\([[:xdigit:]]\\{2\\}\\)?"
                                               this i)
                                 i)
                             (match-beginning 1))
                        (progn
                          (insert (read (concat "?\\x" (match-string 1 this))))
                          (setq i (+ i 2)))
                      (insert "\\x")))
                (?N (let (n)
                      (if (and (eq (string-match "N\\(?:{\\([^}]*\\)}\\)?"
                                                 this i)
                                   i)
                               (setq n (match-string 1 this))
                               (setq n (char-from-name n)))
                          (progn
                            (insert n)
                            (setq i (1- (match-end 0))))
                        (insert "\\N"))))
                ((?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7)
                 (unless (eq (string-match "[0-7]\\{1,3\\}" this i) i)
                   (error "Internal error"))
                 (insert (read (concat "?\\" (match-string 0 this))))
                 (setq i (1- (match-end 0))))
                (t (insert ?\\ n)))))))))

    (insert ?\")
    (insert-char ?\# hashes)
    (goto-char dst)))

(defun mudlle-fontify-doc-string ()
  "Fontify the mudlle documentation string that just matched
`mudlle-anchored-partial-string-regexp'."
  (let ((string-end (point)))
    (goto-char (match-beginning 0))
    (while (re-search-forward mudlle-help-markup-regexp string-end 'limit)
      (font-lock-apply-highlight '(1 font-lock-constant-face prepend)))))

(defun mudlle-fontify-defun (limit)
  "Fontifies the mudlle function starting at point, which must be
right after the \"fn\" keyword, until LIMIT."
  (mudlle-skip-comment limit)
  (when (re-search-forward mudlle-anchored-partial-string-regexp
                           limit t)
    (while (and (prog1 (match-beginning 1)     ; last double quote
                  (mudlle-fontify-doc-string))
		(mudlle-skip-comment limit)
		(eq (char-after) ?+))
		(progn
		  (forward-char)
		  (mudlle-skip-comment limit)
		  (when (re-search-forward
                         mudlle-anchored-partial-string-regexp
                         limit t)
                    (mudlle-fontify-doc-string)
                    t))))
  (mudlle-skip-comment limit)
  (cond ((re-search-forward mudlle-anchored-symbol-regexp limit t)
	 (font-lock-apply-highlight
	  '(0 font-lock-variable-name-face)))
	((re-search-forward "\\=([[:space:]\n]*" limit t)
	 (while (progn
		  (mudlle-skip-comment limit)
		  (and (cond ((re-search-forward
                               mudlle-anchored-formal-argument-regexp
                               limit t)
                              (mudlle-fontify-typeset 1)
                              (font-lock-apply-highlight
                               '(2 font-lock-variable-name-face))
                              t)
                             ((re-search-forward "\\=\\s-*@\\s-*" limit t)
                              (mudlle-fontify-complex-argument limit)))
                       (mudlle-skip-comment limit)
                       (cond ((eq (char-after) ?=)
                              (and (< (point) limit)
                                   (or (forward-char) t)
                                   (mudlle-forward-expr limit)
                                   (mudlle-skip-comment limit)))
                             (t))
                       (eq (char-after) ?,)
                       (< (point) limit)
                       (or (forward-char) t)))
           ))))

(defconst mudlle-defun-regexp
  (concat "\\(?:\\(" mudlle-symbol-regexp "\\)[[:space:]\n]*"
	  "=[[:space:]\n]*\\)?"
	  "\\(" mudlle-typeset-regexp "[[:space:]\n]*\\)?"
	  "\\<fn\\>")
  "Regular expression matching a mudlle function, ending after the \"fn\"
keyword.
The first submatch, if present, is the function name.
The second submatch, if present, contains the return typeset.")

(defun mudlle-fontify-defuns (limit)
  "Fontifies all mudlle functions between point and LIMIT for
`font-lock-mode'."
  (while (re-search-forward mudlle-defun-regexp limit t)
    (let ((start (match-beginning 0)))
      (font-lock-apply-highlight '(1 font-lock-function-name-face nil t))
      (mudlle-fontify-typeset 2)
      (mudlle-fontify-defun limit)
      (when (< start (line-beginning-position))
	(put-text-property start (point) 'font-lock-multiline t)))))

(defun mudlle-fontify-local-vars (limit)
  "Fontifies all mudlle local variable declarations between point
and LIMIT for `font-lock-mode'."
  (while (re-search-forward "\\<for\\>[[:space:]\n]*\\((\\)?\\|\\([[;]\\)"
                            limit t)
    (let ((start (match-beginning 0)))
      (when (and (or (match-beginning 1)
                     (match-beginning 2))
                 (mudlle-skip-comment limit)
                 (eq (char-after) ?|))
	(forward-char)
	(while (progn
		 (mudlle-skip-comment limit)
		 (when (re-search-forward mudlle-anchored-symbol-regexp
                                          limit t)
		   (font-lock-apply-highlight
		    '(0 font-lock-variable-name-face))
		   (when (and (mudlle-skip-comment limit)
			      (eq (char-after) ?,))
		     (forward-char)
		     (mudlle-skip-comment limit)
		     t)))))
      (when (< start (line-beginning-position))
	(put-text-property start (point) 'font-lock-multiline t)))))

(defconst mudlle-header-keywords
  '("library" "module" "requires" "reads" "writes" "static" "defines")
  "Keywords used in the mudlle file headers.")

(defconst mudlle-bol-keyword-regexp
  (concat "^\\s-*" (regexp-opt mudlle-header-keywords 'symbols))
  "Regular expression matching the mudlle file header keywords
that should be indented at the beginning of the line. Its first
parenthesized expression is the keyword.")

(defconst mudlle-font-lock-keywords
  `(,(regexp-opt '("#arith" "fn" "if" "else" "while" "for"
                   "exit" "loop" "match" "match!")
                 'symbols)
    (,mudlle-bol-keyword-regexp . 1)
    (,mudlle-character-constant-regexp . font-lock-string-face)
    (mudlle-fontify-local-vars)
    (,(concat "<[[:space:]\n]*\\(" mudlle-symbol-regexp "\\)[[:space:]\n]*>")
     (1 font-lock-constant-face))
    (mudlle-fontify-defuns))
  "Settings for `font-lock-defaults' in `mudlle-mode'.")

(defgroup mudlle nil "Major mode for mudlle."
  :group 'languages
  :prefix "mudlle-")

(defcustom mudlle-help-highlight-face 'bold
  "Face used by `mudlle-help' to highlight variable names."
  :group 'mudlle
  :type 'face)

(defcustom mudlle-source-path nil
  "Top directory of mudlle source tree."
  :group 'mudlle
  :type  '(choice (const nil :Tag none) (directory)))
(defcustom mudlle-c-source-path nil
  "Top directory of mudlle's C source tree."
  :group 'mudlle
  :type  '(choice (const nil :Tag none) (directory)))

(defcustom mudlle-indent-level 2
  "Indentation of mudlle statements with respect to containing block."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-brace-imaginary-offset 0
  "Imagined indentation of a mudlle open brace that actually
follows a statement."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-brace-offset 0
  "Extra indentation for braces, compared with other text in same context."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-argdecl-indent 5
  "Indentation level of declarations of mudlle function arguments."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-continued-statement-offset 2
  "Extra indent for lines not starting new statements."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-continued-brace-offset 0
  "Extra indent for substatements that start with open-braces.
This is in addition to mudlle-continued-statement-offset."
  :type 'integer
  :group 'mudlle
  :safe #'integerp)
(defcustom mudlle-auto-newline nil
  "Non-nil means automatically newline before and after braces,
and after colons and semicolons, inserted in mudlle code."
  :type 'boolean
  :group 'mudlle)
(defcustom mudlle-tab-always-indent t
  "Non-nil means TAB in mudlle mode should always reindent the current line,
regardless of where in the line point is when the TAB command is used."
  :type 'boolean
  :group 'mudlle)
(defcustom mudlle-function-data-file nil
  "File name to load in order to set the variable `mudlle-functions' to an
alist with mudlle documentation."
  :type '(choice (const nil :tag None) (file :must-match t))
  :group 'mudlle)

(defcustom mudlle-mode-hook nil
  "Hook run by `mudlle-mode'."
  :type 'hook
  :group 'mudlle)

(define-derived-mode mudlle-mode prog-mode
  "mudlle"
  "Major mode for editing mudlle code.

The hook `mudlle-mode-hook' is run with no args at mode initialization.
\\{mudlle-mode-map}
Variables controlling indentation style:
 `mudlle-tab-always-indent'
    Non-nil means TAB in mudlle mode should always reindent the current line,
    regardless of where in the line point is when the TAB command is used.
 `mudlle-auto-newline'
    Non-nil means automatically newline before and after braces,
    and after colons and semicolons, inserted in mudlle code.
 `mudlle-indent-level'
    Indentation of mudlle statements within surrounding block.
    The surrounding block's indentation is the indentation
    of the line on which the open-brace appears.
 `mudlle-continued-statement-offset'
    Extra indentation given to a substatement, such as the
    then-clause of an if or body of a while.
 `mudlle-continued-brace-offset'
    Extra indentation given to a brace that starts a substatement.
    This is in addition to mudlle-continued-statement-offset.
 `mudlle-brace-offset'
    Extra indentation for line if it starts with an open brace.
 `mudlle-brace-imaginary-offset'
    An open brace following other text is treated as if it were
    this far to the right of the start of its line.
 `mudlle-argdecl-indent'
    Indentation level of declarations of mudlle function arguments.
 `mudlle-function-data-file'
    Data file of mudlle functions."
  :group 'mudlle
  (use-local-map mudlle-mode-map)
  (set-syntax-table mudlle-mode-syntax-table)
  (setq-local paragraph-start (concat "\\[$\\|\f\\|[ \t]*\\(?:"
                                      (regexp-opt mudlle-header-keywords)
                                      "\\)")
              eldoc-documentation-function 'mudlle-eldoc-function
              paragraph-separate "[ \t]*$"
              paragraph-ignore-fill-prefix t
              indent-line-function 'mudlle-indent-line
              require-final-newline t
              comment-start "// "
              comment-end ""
              comment-column 32
              comment-start-skip "// *"
              comment-indent-function 'mudlle-comment-indent
              dabbrev-abbrev-skip-leading-regexp "!"
              syntax-propertize-function
              mudlle-syntax-propertize-function
              syntax-propertize-extend-region-functions
              '(syntax-propertize-wholelines syntax-propertize-multiline)
              font-lock-defaults '(mudlle-font-lock-keywords
	                           nil
	                           case-fold
	                           ((?_ . "w"))
	                           mudlle-beginning-of-defun
	                           (font-lock-multiline . t))
              parse-sexp-ignore-comments t
              beginning-of-defun-function 'mudlle-beginning-of-defun
              compilation-error-screen-columns nil)
  (run-hooks 'mudlle-mode-hook))

;; This is used by indent-for-comment
;; to decide how much to indent a comment in mudlle code
;; based on its context.
(defun mudlle-comment-indent ()
  (if (looking-at "^//")
      0				;Existing comment at bol stays there.
    (save-excursion
      (skip-syntax-backward "-")
      (max (1+ (current-column))	;Else indent at comment column
	   comment-column))))	; except leave at least one space.

(defun electric-mudlle-brace (arg)
  "Insert character and correct line's indentation."
  (interactive "P")
  (let (insertpos)
    (when (and (not arg)
	       (eolp)
	       (or (save-excursion
		     (skip-syntax-backward "-")
		     (bolp))
		   (when mudlle-auto-newline
		     (mudlle-indent-line)
		     (newline)
		     t)))
      (insert last-command-event)
      (mudlle-indent-line)
      (when mudlle-auto-newline
	(newline)
	;; (newline) may have done auto-fill
	(setq insertpos (- (point) 2))
	(mudlle-indent-line))
      (save-excursion
	(if insertpos (goto-char (1+ insertpos)))
	(delete-char -1)))
    (if insertpos
	(save-excursion
	  (goto-char insertpos)
	  (self-insert-command (prefix-numeric-value arg)))
      (self-insert-command (prefix-numeric-value arg)))))

(defun electric-mudlle-semi (arg)
  "Insert character and correct line's indentation."
  (interactive "P")
  (self-insert-command (prefix-numeric-value arg))
  (when mudlle-auto-newline
    (mudlle-indent-command)
    (newline)
    (mudlle-indent-command)))

(defun mudlle-indent-command (&optional whole-exp)
  "Indent current line as mudlle code, or in some cases insert a tab character.
If mudlle-tab-always-indent is non-nil (the default), always indent current
line.
Otherwise, indent the current line only if point is at the left margin
or in the line's indentation; otherwise insert a tab.

A numeric argument, regardless of its value,
means indent rigidly all the lines of the expression starting after point
so that this line becomes properly indented.
The relative indentation among the lines of the expression are preserved."
  (interactive "P")
  (if whole-exp
      ;; If arg, always indent this line as mudlle
      ;; and shift remaining lines of expression the same amount.
      (let ((shift-amt (mudlle-indent-line))
	    beg end)
	(save-excursion
	  (if mudlle-tab-always-indent
	      (forward-line 0))
	  (setq beg (point))
	  (forward-sexp 1)
	  (setq end (point))
	  (goto-char beg)
	  (forward-line 1)
	  (setq beg (point)))
	(if (> end beg)
	    (indent-code-rigidly beg end shift-amt)))
    (if (and (not mudlle-tab-always-indent)
	     (save-excursion
	       (skip-syntax-backward "-")
	       (not (bolp))))
	(insert-tab)
      (mudlle-indent-line))))

(defun mudlle-indent-line ()
  "Indent current line as mudlle code.
Return the amount the indentation changed by."
  (let ((indent (calculate-mudlle-indent nil))
        beg shift-amt
        (case-fold-search nil)
        (pos (- (point-max) (point))))
    (forward-line 0)
    (setq beg (point))
    (cond ((eq indent nil)
           (setq indent (current-indentation)))
          ((eq indent t))
          (t
           (skip-syntax-forward "-")
           (if (listp indent) (setq indent (car indent)))
           (cond ((looking-at "\\<else\\>")
                  (setq indent (save-excursion
                                 (mudlle-backward-to-start-of-if)
                                 (current-indentation))))
                 ((= (following-char) ?\])
                  (setq indent (- indent mudlle-indent-level)))
                 ((= (following-char) ?\[)
                  (setq indent (+ indent mudlle-brace-offset))))))
    (skip-syntax-forward "-")
    (when (eq indent t)
      (setq indent (current-column)))
    (setq shift-amt (- indent (current-column)))
    (if (zerop shift-amt)
        (if (> (- (point-max) pos) (point))
            (goto-char (- (point-max) pos)))
      (delete-region beg (point))
      (indent-to indent)
      ;; If initial point was within line's indentation,
      ;; position after the indentation.  Else stay at same point in text.
      (if (> (- (point-max) pos) (point))
          (goto-char (- (point-max) pos))))
    shift-amt))

(defun at-mudlle-statementp (start end)
  (save-excursion
    (goto-char start)
    (cond ((/= (char-after start) ?\[)
	   nil)
	  ((re-search-backward "'\\(\\s-\\|\n\\)*\\=" nil t)
	   nil)
	  (t
	   t))))

(defun calculate-mudlle-indent (&optional parse-start)
  "Return appropriate indentation for current line as mudlle code.
In usual case returns an integer: the column to indent to.
Returns nil if line starts inside a string, t if in a comment."
  (save-excursion
    (forward-line 0)
    (let ((indent-point (point))
	  (case-fold-search nil)
	  state
	  containing-sexp
          (parse-start (or parse-start (point-min))))
      (goto-char parse-start)
      (while (< (point) indent-point)
	(setq parse-start     (point)
              state           (parse-partial-sexp parse-start indent-point 0)
              containing-sexp (cadr state)))

      (when (and containing-sexp
		 (= (char-after containing-sexp) ?\[))
	(save-excursion
	  (goto-char containing-sexp)
	  (when (re-search-forward "\\=\\[[[:space:]\n]*|" indent-point t)
            (let ((open-bar (point)))
              (and (looking-at "\\([^|]*\\)")
                   (>= (match-end 1) indent-point)
                   (setq containing-sexp (1- open-bar)))))))

      (cond ((or (nth 3 state) (nth 4 state))
	     ;; return nil or t if should not change this line
	     (nth 4 state))
	    ((looking-at mudlle-bol-keyword-regexp)
	     0)
	    ((null containing-sexp)
	     ;; Line is at top level.  May be data or function definition,
	     ;; or may be function argument declaration.
	     ;; Indent like the previous top level line
	     ;; unless that ends in a closeparen without semicolon,
	     ;; in which case this line is the first argument decl.
	     (goto-char indent-point)
	     (skip-syntax-forward "-")
	     (if (= (following-char) ?\[)
		 0   ; Unless it starts a function body
	       (mudlle-backward-to-noncomment parse-start)
	       ;; Add a little if this is a continuation line.
	       (if (or (bobp)
		       (memq (preceding-char) '(?\) ?\; ?\])))
		   0 mudlle-continued-statement-offset)))
	    ((not (at-mudlle-statementp containing-sexp indent-point))
	     ;; line is expression, not statement:
	     ;; indent to just after the surrounding open.
	     (goto-char (1+ containing-sexp))
	     (when (looking-at "[ \t]*[^ \t\n]")
	       (skip-syntax-forward "-"))
             ;; if the open is just before end of line (ignoring
             ;; comments), indent an extra mudlle-indent-level
             (if (not (looking-at mudlle-end-of-line-regexp))
                 (current-column)
               (forward-line 0)
               (skip-syntax-forward "-")
               (+ (current-column) mudlle-indent-level)))
	    (t
	     ;; Statement level.  Is it a continuation or a new statement?
	     ;; Find previous non-comment character.
	     (goto-char indent-point)
	     (mudlle-backward-to-noncomment containing-sexp)
	     ;; Now we get the answer.
	     (if (and (not (memq (preceding-char) '(nil ?\; ?\[ ?\|)))
		      (save-excursion
			(goto-char indent-point)
			(skip-chars-forward " \t\n\f")
			(/= (following-char) ?\])))
		 ;; This line is continuation of preceding line's statement;
		 ;; indent  mudlle-continued-statement-offset  more than the
		 ;; previous line of the statement.
		 (progn
		   (mudlle-backward-to-start-of-continued-exp containing-sexp)
		   (+ mudlle-continued-statement-offset (current-column)
		      (if (save-excursion (goto-char indent-point)
					  (skip-syntax-forward "-")
					  (eq (following-char) ?\[))
			  mudlle-continued-brace-offset 0)))
	       ;; This line starts a new statement.
	       ;; Position following last unclosed open.
	       (goto-char containing-sexp)
	       ;; Is line first statement after an open-brace?
	       (or
		 ;; If no, find that first statement and indent like it.
		 (save-excursion
		   (forward-char 1)
		   (while (progn (skip-chars-forward " \t\n")
				 (looking-at "//"))
		     ;; Skip over comments following openbrace.
		     (forward-line 1))
		   ;; The first following code counts
		   ;; if it is before the line we want to indent.
		   (and (< (point) indent-point)
			(- (current-column)
			   (if (= (following-char) ?\[)
                               mudlle-brace-offset
                             0))))
		 ;; If no previous statement,
		 ;; indent it relative to line brace is on.
		 ;; For open brace in column zero, don't let statement
		 ;; start there too.  If mudlle-indent-level is zero,
		 ;; use mudlle-brace-offset
                 ;;     + mudlle-continued-statement-offset instead.
		 ;; For open-braces not the first thing in a line,
		 ;; add in mudlle-brace-imaginary-offset.
		 (+ (if (and (bolp) (zerop mudlle-indent-level))
			(+ mudlle-brace-offset
                           mudlle-continued-statement-offset)
		      mudlle-indent-level)
		    ;; Move back over whitespace before the openbrace.
		    ;; If openbrace is not first nonwhite thing on the line,
		    ;; add the mudlle-brace-imaginary-offset.
		    (progn (skip-syntax-backward "-")
			   (if (bolp) 0 mudlle-brace-imaginary-offset))
		    ;; If the openbrace is preceded by a parenthesized exp,
		    ;; move to the beginning of that;
		    ;; possibly a different line
		    (progn
		      (if (eq (preceding-char) ?\))
			  (forward-sexp -1))
		      ;; Get initial indentation of the line we are on.
		      (current-indentation))))))))))

(defun mudlle-beginning-of-defun ()
  (cl-loop do
           (search-backward-regexp "\\<fn\\>\\(?:\n\\|\\s-\\)*[\"(a-zA-Z]" nil
                                   'point-min-on-fail)
           while (let* ((where (point))
                        (start (save-excursion
                                 (while (and (end-of-line 0)
                                             (= (preceding-char) ?\\)))
                                 (forward-line 0)
                                 (point)))
                        (parse-state (parse-partial-sexp start where))
                        (in-string   (nth 3 parse-state))
                        (in-comment  (nth 4 parse-state)))
                   (or in-string in-comment))))

(defun mudlle-backward-to-noncomment (lim)
  (while
      (let ((start (progn
                     (skip-chars-backward " \t\n\f" lim)
                     (point))))
        (when (looking-back "\\*/" lim)
          (forward-char -1))

        (let* ((state         (parse-partial-sexp lim (point)))
               (comment       (nth 4 state))
               (comment-start (nth 8 state)))
          (cond ((and comment comment-start (<= lim comment-start))
                 (goto-char comment-start)
                 t)                     ; continue loop
                (t
                 (goto-char start)
                 nil))))))              ; break loop

(defun mudlle-backward-to-start-of-continued-exp (lim)
  (if (= (preceding-char) ?\))
      (forward-sexp -1))
  (forward-line 0)

  (let ((ppss (syntax-ppss)))
    (while (nth 3 ppss)
      (goto-char (nth 8 ppss))
      (forward-line 0)
      (setq ppss (syntax-ppss))))

  (if (<= (point) lim)
      (goto-char (1+ lim)))
  (skip-syntax-forward "-"))

(defun mudlle-backward-to-start-of-if (&optional limit)
  "Move to the start of the last unbalanced \"if\"."
  (unless limit (setq limit (point-min)))
  (let ((if-level 1)
        (case-fold-search nil))
    (while (not (zerop if-level))
      (backward-sexp 1)
      (cond ((looking-at "else\\>")
             (setq if-level (1+ if-level)))
            ((looking-at "if\\>")
             (setq if-level (1- if-level)))
            ((< (point) limit)
             (setq if-level 0)
             (goto-char limit))))))

(defvar mudlle-functions nil
  "An alist or hash table with the help text on mudlle functions.
Typically set by loading the file specified by `mudlle-function-data-file'.
The function `mudlle-functions' will convert it to an alist if necessary.

Each entry is a (NAME DOC TYPE FILE LINE COLUMN LIBRARY &optional SECLEV)
  NAME     name of the symbol, a string
  DOC      documentation string
  TYPE     type symbol; one of closure, primitive, secure, varargs, or variable
  FILE     file name or nil
  LINE     line number or nil
  COLUMN   column number or nil
  LIBRARY  name of the defining mudlle library or t for built-ins
  SECLEV   security level; it is only present for type secure.")
(when mudlle-function-data-file
  (load mudlle-function-data-file t))

(defun mudlle-symbol-hash-test (a b)
  (eq t (compare-strings a nil nil b nil nil t)))

(defun mudlle-symbol-hash-hash (a)
  (sxhash (upcase a)))

;; Case-insensitive string keys
(define-hash-table-test 'mudlle-symbol-hash-test
  #'mudlle-symbol-hash-test
  #'mudlle-symbol-hash-hash)

(defun mudlle-functions ()
  "Returns the hash table of documented mudlle functions.

Updates the variable `mudlle-functions' from an alist to a hash table if
necessary."
  (if (hash-table-p mudlle-functions)
      mudlle-functions
    (let ((h (make-hash-table :test 'mudlle-symbol-hash-test
                              :size (safe-length mudlle-functions))))
      (cl-loop for entry in mudlle-functions do
               (puthash (car entry) entry h))
      (setq mudlle-functions h))))

(defun mudlle-find-symbol-start (&optional at-point)
  "Return the starting position of the symbol starting at or closest before
point. If AT-POINT is non-nil, only consider symbols ending on or after point."
  (save-excursion
    (let ((pos (point))
          start)
      (when (or (looking-at "\\<[a-zA-Z]")
                (search-backward-regexp "\\<[a-zA-Z]" (point-min) t))
        (unless at-point (setq pos (point)))
        (while (and (looking-at mudlle-symbol-regexp)
                    (>= (match-end 0) pos)
                    (setq start (point))
                    (search-backward-regexp "\\<[a-zA-Z]" (point-min) t))))
      start)))

(defun mudlle-complete-symbol ()
  "Perform completion on Mudlle symbol preceding point"
  (interactive)
  (let* ((end (point))
         (beg (or (mudlle-find-symbol-start)
                  (error "Nothing to complete")))
         (pattern (buffer-substring-no-properties beg end))
         (completion-ignore-case t)
         (completion (try-completion pattern (mudlle-functions))))
    (cond ((eq completion t))
          ((null completion)
           (error "Can't find completion for \"%s\"" pattern))
          ((not (string-equal pattern completion))
           (delete-region beg end)
           (insert completion))
          (t
           (message "Making completion list...")
           (with-output-to-temp-buffer "*Completions*"
             (display-completion-list
              (all-completions pattern (mudlle-functions))))
           (message "Making completion list...done")))))

(defconst mudlle-nbsp ?\u00a0
  "The no-break space character.")

(defun mudlle-apropos-abbreviate (str)
  (let ((width (- (min fill-column (- (window-width) 1)) 8))
        cut)
    (when (string-match "\n" str)
      (setq str (substring str 0 (match-beginning 0))
	    cut t))
    (setq str (replace-regexp-in-string "\t" "" str))
    (when (> (length str) width)
      (setq str (substring str 0 width)
	    cut t))
    (setq str (replace-regexp-in-string (string mudlle-nbsp) " " str))
    (if cut
	(concat str " ...")
      str)))

(define-derived-mode mudlle-apropos-mode special-mode "Mudlle Apropos"
  "Major mode for following hyperlinks in output of mudlle-apropos command.

\\{mudlle-apropos-mode-map}")

(defun mudlle-apropos-follow ()
  "Follow cross-reference at point."
  (interactive)
  (save-excursion
    (forward-line 0)
    (let ((kw (get-text-property (point) 'mudlle-item)))
      (mudlle-help kw))))

(defun mudlle-apropos-next (&optional arg)
  "Move to the next entry, or the ARG'th next."
  (interactive "p")
  (unless arg (setq arg 1))
  (cl-destructuring-bind (op . lim)
      (if (< arg 0)
          `(previous-single-property-change . ,(point-min))
        '(next-single-property-change . nil))
    (cl-loop repeat (abs arg)
             do (let ((p (funcall op (point) 'mudlle-item nil lim)))
                  (unless (and p (/= (point) p))
                    (error "No more entries"))
                  (goto-char p)))))

(defun mudlle-apropos-previous (&optional arg)
  "Move to the previous entry, or ARG'th previous."
  (interactive "p")
  (mudlle-apropos-next (if arg (- arg) -1)))

(defmacro mudlle-ahelp-bind (ahelp &rest body)
  "Bind ah:name, ah:help, ah:type, ah:file, ah:line, ah:column, ah:library,
and ah:seclev to the fields in AHELP and execute BODY."
  (declare (indent 1) (debug t))
  `(cl-destructuring-bind
       (ah:name ah:help ah:type ah:file ah:line ah:column ah:library
                &optional ah:seclev)
      ,ahelp
    ,@body))

(defun mudlle-apropos (regexp &optional name-only)
  "Search for mudlle symbols whose name or documentation matches REGEXP.
If NAME-ONLY is non-nil, only match the symbol names."
  (interactive "sApropos mudlle function (regexp): ")
  (switch-to-buffer (get-buffer-create "*Mudlle apropos*"))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (mudlle-apropos-mode)
    (let ((case-fold-search t))
      (cl-loop
       for ahelp in
       (sort (cl-loop for ahelp being the hash-values of (mudlle-functions)
                      when (mudlle-ahelp-bind ahelp
                             (or (string-match regexp ah:name)
                                 (and ah:help (string-match regexp ah:help))))
                      collect ahelp)
             (lambda (a b) (< (compare-strings (car a) nil nil
                                               (car b) nil nil t)
                              0)))
       do
       (mudlle-ahelp-bind ahelp
         (let ((help (and ah:help (mudlle-apropos-abbreviate ah:help))))
           (insert (propertize (format "%-38s  %s\n    %s\n"
                                       (propertize ah:name 'face 'bold)
                                       ah:type
                                       (or help "<no help>"))
                               'mudlle-item ah:name))))))
    (when (= (point-min) (point-max))
      (insert "No matches found."))
    (goto-char (point-min))))

(defun mudlle-find-pos (path file line column)
  "Open FILE in directory PATH at line number LINE and column number COLUMN.

LINE can also be a string of a symbol definition to find."
  (setq file (concat path "/" file))
  (unless (file-readable-p file)
    (error "Cannot open file `%s'" file))
  (find-file file)
  (cond ((numberp line)
         (goto-char (point-min))
         (forward-line (1- line))
         (when (numberp column)
           (forward-char (1- column))))
        ((save-excursion
           (goto-char (point-min))
           (let ((line-re (regexp-quote line)))
             (or (re-search-forward (concat "\\<" line-re "\\s-*=[^=]")
                                    nil t)
                 (re-search-forward (concat "\\<document\\s-*(\\s-*\""
                                            line-re "\"")
                                    nil t))))
         (goto-char (match-beginning 0)))))

(eval-and-compile
  (if (< emacs-major-version 22)
      (defun mudlle-find-file-button (path file line column)
	(help-xref-button 0 'mudlle-find-pos
			  (list path file line column)))

    (defun mudlle-find-file-button (path file line column)
      (help-xref-button 0 'mudlle-find-pos
			path file line column))

    (define-button-type 'mudlle-find-pos
      :supertype 'help-xref
      'help-function 'mudlle-find-pos)

    (define-button-type 'mudlle-help
      :supertype 'help-xref
      'help-function 'mudlle-help)

    (define-button-type 'mudlle-apropos
      :supertype 'help-xref
      'help-function 'mudlle-apropos)))

(defun mudlle-symbol-at-point (&optional at-point)
  "Return the name of the symbol starting closest before point.
If AT-POINT is non-nil, only conside symbols ending on or after point."
  (let ((beg (mudlle-find-symbol-start at-point))
        (old-point (point)))
    (when beg
      (goto-char beg)
      (prog1
          (when (looking-at mudlle-symbol-regexp)
            (match-string-no-properties 0))
        (goto-char old-point)))))

(defconst mudlle-help-abbrev-regexp
  "\\(\\(?:\\<\\(?:[Cc]f\\|[Ii]\\.?e\\|[Ee]\\.?g\\)\\.\\),?\\) ")

(defun mudlle-help-string (help-text)
  (cond ((stringp help-text)
         (replace-regexp-in-string mudlle-help-abbrev-regexp
                                   (concat "\\1" `[ ,mudlle-nbsp ])
                                   help-text))
        ((not help-text) "No help text.")
        (t (format "%s" help-text))))

(defun mudlle-help-print (ahelp)
  (let ((path mudlle-c-source-path)
        column line file)
    (mudlle-ahelp-bind ahelp
      (setq column ah:column
            line   ah:line
            file   ah:file)
      (princ (format "%s is a " ah:name))

      (cl-destructuring-bind (typename is-primitive)
          (cl-case ah:type
            (closure   (if (and mudlle-c-source-path
                                (string-match "^compiler/" file))
                           (setq file (concat "mudlle/"
                                              (substring file 9)))
                         (setq path mudlle-source-path))
                       '("closure" nil))
            (primitive '("primitive" t))
            (varargs   '("vararg primitive" t))
            (secure    `(,(format "secure %d primitive" ah:seclev) t))
            (variable  (setq line   ah:name
                             column nil
                             path   mudlle-source-path)
                       '("variable" nil))
            (t         '("something weird" nil)))

        (cl-destructuring-bind ((built-in prefix) (infix desc suffix))
            (list (cond (is-primitive
                         '("" ""))
                        ((eq ah:library t)
                         `("built-in "
                           ,(if (and (eq ah:type 'variable) file)
                                " documented"
                              "")))
                        (t '("" "")))
                  (if (stringp ah:library)
                      `("the " ,ah:library " library")
                    `("" ,file "")))
          (princ built-in)
          (princ typename)
          (princ prefix)
          (when desc
            (princ (format " in %s%s" infix desc))
            (when path
              (save-excursion
                (when (re-search-backward (regexp-quote desc))
                  (mudlle-find-file-button path file line column))))
            (princ suffix))))

      (princ "\n\n")

      (let ((start (point)))
        (insert (mudlle-help-string ah:help))
        (goto-char start)))
    )
  )

(defun mudlle-help-fontify ()
  (let ((start (point)))
    ;; fontify backtick-prefixed variables
    (while (re-search-forward mudlle-help-markup-regexp nil t)
      (let ((start (match-beginning 0))
            text)
        (while (progn (setq text (cons (match-string 1) text))
                      (goto-char (match-end 0))
                      (looking-at mudlle-help-markup-regexp)))
        (delete-region start (point))
        (setq text (apply 'concat (nreverse text)))

        (cond ((gethash text (mudlle-functions))
               (help-insert-xref-button text 'mudlle-help text))
              ((let ((case-fold-search t) is-prefix)
                 (when (cond ((string-match "\\`\\(.*\\)xxx\\'" text)
                              (setq is-prefix t))
                             ((string-match "\\`xxx\\(.*\\)\\'" text)))
                   (let ((substr (match-string 1 text)))
                     (when (cl-loop for name being the hash-keys
                                    of (mudlle-functions)
                                    thereis (funcall (if is-prefix
                                                         #'string-prefix-p
                                                       #'string-suffix-p)
                                                     substr name t))
                       (help-insert-xref-button
                        text
                        'mudlle-apropos
                        (concat (when is-prefix "\\`")
                                (regexp-quote substr)
                                (unless is-prefix "\\'")))
                       t)))))
              (t (insert text)
                 (put-text-property start (point)
                                    'face mudlle-help-highlight-face)))))
    (goto-char start)))

(defun mudlle-help-indent ()
  ;; line wrap
  (let ((tab 0)
        (col 0)
        (word 0)
        (c t)
        (endc (min fill-column (- (window-width) 1))))
    (while c
      (while (and c (< col endc))
        (setq c (char-after))
        (cond ((null c))
              ((= c ?\t)
               (setq tab col)
               (delete-char 1))
              ((= c ?\n)
               (forward-char 1)
               (setq col 0
                     tab 0
                     word 0))
              (t
               (forward-char 1)
               (setq col (1+ col))
               (cond ((= c ?\ )
                      (setq word col))
                     ((= c mudlle-nbsp)
                      (delete-char -1)
                      (insert-char ?\  1))))))
      (when c
        (when (> word tab)
          (backward-char (- col word)))
        ;; remove trailing whitespace
        (when (looking-back " +" nil t)
          (goto-char (match-beginning 0)))
        (when (looking-at " +")
          (delete-char (- (match-end 0) (match-beginning 0))))
        (insert-char ?\n 1)
        (insert-char ?\  tab)
        (setq col tab
              word tab)))))

(eldoc-add-command 'mudlle-indent-command
                   'mudlle-complete-symbol)

(defun mudlle-eldoc-function ()
  "Return a documentation string appropriate for the current context, or nil."
  (let* ((sym (mudlle-symbol-at-point t))
         (ahelp (and sym (gethash sym (mudlle-functions)))))
    (when ahelp
      (mudlle-ahelp-bind ahelp
        (let ((text (mudlle-help-string ah:help)))
          ;; remove any leading "Alias for ..." line
          (when (string-match "\\`Alias for \\(?:local function \\)?\\S-*\n"
                              text)
            (setq text (substring text (match-end 0))))
          ;; only show one line
          (when (string-match "\n" text)
            (setq text (substring text 0 (match-beginning 0))))

          (setq text (concat ah:name ": " text))

          (let ((start 0)
                (width (window-width (minibuffer-window)))
                (re    (concat mudlle-help-markup-regexp
                               "\\|[" `(?\t ,mudlle-nbsp) "]")))
            ;; handle backticks, tab, and no-break space
            (while (and (< start width)
                        (string-match re text start))
              (let ((sym (match-string 1 text)))
                (put-text-property 0 (length sym)
                                   'face 'eldoc-highlight-function-argument
                                   sym)
                (unless sym
                  (when (= (elt text (match-beginning 0)) mudlle-nbsp)
                    (setq sym " ")))

                (setq text (concat
                            (substring text 0 (match-beginning 0))
                            sym
                            (substring text (match-end 0)))
                      start (+ (match-beginning 0) (length sym)))))

            ;; fit to window width
            (when (>= (length text) width)
              (string-match (format "\\`\\(?:.\\{,%d\\}\\_>\\|\\S-\\{,%d\\}\\)"
                                    (1- width) (1- width))
                            text)
              (setq text (match-string 0 text))))

          text)))))

(defun mudlle-help (&optional keyword)
  "Get help on mudlle function"
  (interactive
   (let* ((completion-ignore-case t)
          (fn (mudlle-symbol-at-point))
          (sym (completing-read
                (format "Describe mudlle function%s: "
                        (if fn
                            (format " (default %s)" fn)
                          ""))
                (mudlle-functions)
                nil
                t)))
     (list (if (equal sym "") fn sym))))

  (unless keyword
    (error "You need to specify a keyword"))

  (let ((ahelp (or (gethash keyword (mudlle-functions))
                   (error "No help on `%s'" keyword))))
    (message "Formatting help text...")

    (let ((help-xref-following t)
          (buf (get-buffer "*Mudlle help*")))
      (when buf
        (with-current-buffer buf
          (help-setup-xref (list 'mudlle-help keyword)
                           (called-interactively-p 'interactive)))))

    (with-output-to-temp-buffer "*Mudlle help*"
      (set-buffer standard-output)
      (mudlle-help-print ahelp)
      (mudlle-help-fontify)
      (mudlle-help-indent))

    (message "Formatting help text...done")))

(defun indent-mudlle-exp ()
  "Indent each line of the mudlle grouping following point."
  (interactive)
  (let ((indent-stack (list nil))
	(contain-stack (list (point)))
	(case-fold-search nil)
	restart outer-loop-done inner-loop-done state ostate
	this-indent last-sexp
	at-else at-brace at-close
	(opoint (point))
	(next-depth 0)
        last-depth)
    (save-excursion
      (while (and (not (eobp)) (not outer-loop-done))
	(setq last-depth next-depth)
	;; Compute how depth changes over this line
	;; plus enough other lines to get to one that
	;; does not end inside a comment or string.
	;; Meanwhile, do appropriate indentation on comment lines.
	(setq inner-loop-done nil)
	(while (and (not inner-loop-done)
		    (not (and (eobp) (setq outer-loop-done t))))
	  (setq ostate state)
	  (setq state (parse-partial-sexp (point) (progn (end-of-line) (point))
					  nil nil state))
	  (setq next-depth (car state))
	  (when (and (caddr state)
                     (>= (caddr state) 0))
            (setq last-sexp (caddr state)))
	  (if (nth 4 state)             ; comment
	      (mudlle-indent-line)
	    (setcar (nthcdr 4 state) nil))
	  (if (nth 3 state)             ; string
	      (forward-line 1)
	    (setq inner-loop-done t)))
	(when (<= next-depth 0)
          (setq outer-loop-done t))
	(unless outer-loop-done
	  ;; If this line had ..))) (((.. in it, pop out of the levels
	  ;; that ended anywhere in this line, even if the final depth
	  ;; doesn't indicate that they ended.
	  (while (> last-depth (nth 6 state))
	    (setq indent-stack (cdr indent-stack)
		  contain-stack (cdr contain-stack)
		  last-depth (1- last-depth)))
	  (if (/= last-depth next-depth)
	      (setq last-sexp nil))
	  ;; Add levels for any parens that were started in this line.
	  (while (< last-depth next-depth)
	    (setq indent-stack (cons nil indent-stack)
		  contain-stack (cons nil contain-stack)
		  last-depth (1+ last-depth)))
	  (if (null (car contain-stack))
	      (setcar contain-stack (or (car (cdr state))
					(save-excursion (forward-sexp -1)
							(point)))))
	  (forward-line 1)
	  (skip-syntax-forward "-")
	  (if (eolp)
	      nil
	    (if (and (car indent-stack)
		     (>= (car indent-stack) 0))
		;; Line is on an existing nesting level.
		;; Lines inside parens are handled specially.
		(if (/= (char-after (car contain-stack)) ?\[)
		    (setq this-indent (car indent-stack))
		  ;; Line is at statement level.
		  ;; Is it a new statement?  Is it an else?
		  ;; Find last non-comment character before this line
                  (let ((at-else (looking-at "else\\>"))
                        (at-brace (= (following-char) ?\[))
                        (at-close (= (following-char) ?\])))
                    (save-excursion
                      (mudlle-backward-to-noncomment opoint)
                      (if at-else
                          (progn (mudlle-backward-to-start-of-if opoint)
                                 (setq this-indent (current-indentation)))
                        (when (and (not (memq (preceding-char)
                                              '(nil ?\; ?\[ ?\|)))
                                   (not at-close))
                          ;; Preceding line did not end in comma or semi;
                          ;; indent this line
                          ;; mudlle-continued-statement-offset more
                          ;; than previous.
                          (mudlle-backward-to-start-of-continued-exp
                           (car contain-stack))
                          (setq this-indent
                                (+ mudlle-continued-statement-offset
                                   (current-column)
                                   (if at-brace
                                       mudlle-continued-brace-offset
                                     0))))
			;; Preceding line ended in comma or semi;
			;; use the standard indent for this level.
			(setq this-indent (car indent-stack))))))
	      ;; Just started a new nesting level.
	      ;; Compute the standard indent for this level.
	      (let ((val (calculate-mudlle-indent
                          (if (car indent-stack)
			      (- (car indent-stack))))))
		(setcar indent-stack (setq this-indent val))))
	    ;; Adjust line indentation according to its contents
	    (when (= (following-char) ?\])
              (setq this-indent (- this-indent mudlle-indent-level)))
	    (when (= (following-char) ?\[)
              (setq this-indent (+ this-indent mudlle-brace-offset)))
	    ;; Put chosen indentation into effect.
	    (or (= (current-column) this-indent)
		(progn
		  (delete-region (point) (progn (forward-line 0) (point)))
		  (indent-to this-indent)))
	    ;; Indent any comment following the text.
	    (unless (looking-at comment-start-skip)
              (when (re-search-forward comment-start-skip
                                       (save-excursion (end-of-line) (point))
                                       t)
                (indent-for-comment)
                (forward-line 0)))
	    ))))))

(defconst mudlle-ftaf-ansi-alist
  '((black   . 30)
    (red     . 31)
    (green   . 32)
    (yellow  . 33)
    (blue    . 34)
    (magenta . 35)
    (cyan    . 36)
    (white   . 37))
  "Association-list mapping ANSI color to ANSI escape code for use in
`mudlle-fontify-to-ansi-file'.")

(defconst mudlle-ftaf-color-alist
  '((font-lock-comment-delimiter-face . red)
    (font-lock-comment-face           . red)
    (font-lock-constant-face          . magenta)
    (font-lock-function-name-face     . blue)
    (font-lock-keyword-face           . cyan)
    (font-lock-string-face            . green)
    (font-lock-type-face              . green)
    (font-lock-variable-name-face     . yellow)
    ((font-lock-constant-face font-lock-string-face) . magenta))
  "Association-list mapping face to ANSI color for use in
`mudlle-fontify-to-ansi-file'.")

(defun mudlle-ftaf-print-face-transition (from to)
  "Print, to `standard-output', ANSI escape sequences to transition from
face FROM to face TO."
  (unless (eq from to)
    (let* ((color (assoc to mudlle-ftaf-color-alist))
	   (ansi  (and color (assq (cdr color) mudlle-ftaf-ansi-alist)))
	   (old   mudlle-ftaf-current))
      (cond ((eq old ansi))
	    ((and old (not ansi))
	     (princ "\033[0m"))
	    (t
	     (princ "\033[")
	     (princ (int-to-string (cdr ansi)))
	     (princ "m")))
      (setq mudlle-ftaf-current ansi))))

(defun mudlle-fontify-to-ansi-file (dst)
  "Save the current buffer to the file DST with ANSI escape codes
according to fontification."
  (interactive "FWrite file:")
  (save-excursion
    (let ((src (current-buffer)))
      (with-temp-file dst
        (let ((dstbuf (current-buffer)))
          (with-current-buffer src
	    (setq mudlle-ftaf-current nil)
            (let ((standard-output dstbuf))

              (if (or (< emacs-major-version 25)
                      (and (= emacs-major-version 25)
                           (< emacs-minor-version 1)))
                  (with-no-warnings (font-lock-fontify-buffer))
                (font-lock-ensure (point-min) (point-max)))

              (goto-char (point-min))
              (let ((face (get-text-property (point) 'face)))
                (mudlle-ftaf-print-face-transition nil face)
                (while (< (point) (point-max))
                  (let ((next (next-single-property-change (point) 'face
                                                           (current-buffer)
                                                           (point-max))))
                    (princ (buffer-substring-no-properties (point) next))
                    (goto-char next)
                    (let ((nface (get-text-property (point) 'face)))
                      (mudlle-ftaf-print-face-transition face nface)
                      (setq face nface))))
                (mudlle-ftaf-print-face-transition face nil)))))))))

(provide 'mudlle-mode)
