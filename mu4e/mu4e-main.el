;;; mu4e-main.el -- part of mu4e, the mu mail user agent -*- lexical-binding: t -*-

;; Copyright (C) 2011-2020 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>

;; This file is not part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'smtpmail)      ;; the queueing stuff (silence elint)
(require 'mu4e-utils)    ;; utility functions
(require 'mu4e-context)  ;; the context
(require 'mu4e-vars)     ;; mu-wide variables
(require 'cl-lib)

;;; Mode

(defvar mu4e-main-buffer-hide-personal-addresses nil
  "Whether to hide the personal address in the main view. This
  can be useful to avoid the noise when there are many.

  This also hides the warning if your `user-mail-address' is not
part of the personal addresses.")

(defvar mu4e-main-hide-fully-read nil
  "When set to t, do not hide bookmarks or maildirs that have
no unread messages.")

(defvar mu4e-main-mode-map
  (let ((map (make-sparse-keymap)))

    (define-key map "b" 'mu4e-headers-search-bookmark)
    (define-key map "B" 'mu4e-headers-search-bookmark-edit)

    (define-key map "s" 'mu4e-headers-search)
    (define-key map "q" 'mu4e-quit)
    (define-key map "j" 'mu4e~headers-jump-to-maildir)
    (define-key map "C" 'mu4e-compose-new)

    (define-key map "m" 'mu4e~main-toggle-mail-sending-mode)
    (define-key map "f" 'smtpmail-send-queued-mail)
    ;;
    (define-key map "U" 'mu4e-update-mail-and-index)
    (define-key map  (kbd "C-S-u")   'mu4e-update-mail-and-index)
    ;; for terminal users
    (define-key map  (kbd "C-c C-u") 'mu4e-update-mail-and-index)

    (define-key map "S" 'mu4e-kill-update-mail)
    (define-key map  (kbd "C-S-u") 'mu4e-update-mail-and-index)
    (define-key map ";" 'mu4e-context-switch)

    (define-key map "$" 'mu4e-show-log)
    (define-key map "A" 'mu4e-about)
    (define-key map "N" 'mu4e-news)
    (define-key map "H" 'mu4e-display-manual)
    map)

  "Keymap for the *mu4e-main* buffer.")

(defvar mu4e-main-mode-abbrev-table nil)
(define-derived-mode mu4e-main-mode special-mode "mu4e:main"
  "Major mode for the mu4e main screen.
\\{mu4e-main-mode-map}."
  (setq truncate-lines t
        overwrite-mode 'overwrite-mode-binary)
  (mu4e-context-in-modeline)
  (set (make-local-variable 'revert-buffer-function) #'mu4e~main-view-real))


(defun mu4e~main-action-str (str &optional func-or-shortcut)
  "Highlight the first occurrence of [.] in STR.
If FUNC-OR-SHORTCUT is non-nil and if it is a function, call it
when STR is clicked (using RET or mouse-2); if FUNC-OR-SHORTCUT is
a string, execute the corresponding keyboard action when it is
clicked."
  (let ((newstr
         (replace-regexp-in-string
          "\\[\\(..?\\)\\]"
          (lambda(m)
            (format "[%s]"
                    (propertize (match-string 1 m) 'face 'mu4e-highlight-face)))
          str))
        (map (make-sparse-keymap))
        (func (if (functionp func-or-shortcut)
                  func-or-shortcut
                (if (stringp func-or-shortcut)
                    (lambda()(interactive)
                      (execute-kbd-macro func-or-shortcut))))))
    (define-key map [mouse-2] func)
    (define-key map (kbd "RET") func)
    (put-text-property 0 (length newstr) 'keymap map newstr)
    (put-text-property (string-match "\\[.+$" newstr)
                       ;; only subtract one from length of newstr if we're
                       ;; actually consuming the first letter (e.g.
                       ;; `func-or-shortcut' is a function, meaning we put
                       ;; braces around the first letter of `str')
                       (if (stringp func-or-shortcut)
                           (length newstr)
                         (- (length newstr) 1))
                       'mouse-face 'highlight newstr)
    newstr))

(defun mu4e~main-bookmarks ()
  ;; TODO: it's a bit uncool to hard-code the "b" shortcut...
  (cl-loop with bmks = (mu4e-bookmarks)
           with longest = (mu4e~longest-of-maildirs-and-bookmarks)
           with queries = (mu4e-last-query-results)
           for bm in bmks
           for key = (string (plist-get bm :key))
           for name = (plist-get bm :name)
           for query = (funcall (or mu4e-query-rewrite-function #'identity)
                                (plist-get bm :query))
           for qcounts = (and (stringp query)
                              (cl-loop for q in queries
                                       when (string=
                                             (decode-coding-string
                                              (plist-get q :query) 'utf-8 t)
                                             query)
                                       collect q))
           for unread = (and qcounts (plist-get (car qcounts) :unread))
           when (not (plist-get bm :hide))
           when (not (and mu4e-main-hide-fully-read (eq unread 0)))
           concat (concat
                   ;; menu entry
                   (mu4e~main-action-str
                    (concat "\t* [b" key "] " name)
                    (concat "b" key))
                   ;; append all/unread numbers, if available.
                   (if qcounts
                       (let ((unread (plist-get (car qcounts) :unread))
                             (count  (plist-get (car qcounts) :count)))
                         (format
                          "%s (%s/%s)"
                          (make-string (- longest (string-width name)) ? )
                          (propertize (number-to-string unread)
                                      'face 'mu4e-header-key-face)
                          count))
                     "")
                   "\n")))


(defun mu4e~main-maildirs ()
  "Return a string of maildirs with their counts."
  (cl-loop with mds = (mu4e~maildirs-with-query)
           with longest = (mu4e~longest-of-maildirs-and-bookmarks)
           with queries = (plist-get mu4e~server-props :queries)
           for m in mds
           for key = (string (plist-get m :key))
           for name = (plist-get m :name)
           for query = (plist-get m :query)
           for qcounts = (and (stringp query)
                              (cl-loop for q in queries
                                       when (string=
                                             (decode-coding-string
                                              (plist-get q :query)
                                              'utf-8 t)
                                             query)
                                       collect q))
           for unread = (and qcounts (plist-get (car qcounts) :unread))
           when (not (plist-get m :hide))
           when (not (and mu4e-main-hide-fully-read (eq unread 0)))
           concat (concat
                   ;; menu entry
                   (mu4e~main-action-str
                    (concat "\t* [j" key "] " name)
                    (concat "j" key))
                   ;; append all/unread numbers, if available.
                   (if qcounts
                       (let ((unread (plist-get (car qcounts) :unread))
                             (count  (plist-get (car qcounts) :count)))
                         (format
                          "%s (%s/%s)"
                          (make-string (- longest (string-width name)) ? )
                          (propertize (number-to-string unread)
                                      'face 'mu4e-header-key-face)
                          count))
                     "")
                   "\n")))


(defun mu4e~key-val (key val &optional unit)
  "Return a key / value pair."
  (concat
   "\t* "
   (propertize (format "%-20s" key) 'face 'mu4e-header-title-face)
   ": "
   (propertize val 'face 'mu4e-header-key-face)
   (if unit
       (propertize (concat " " unit) 'face 'mu4e-header-title-face)
     "")
   "\n"))

;; NEW This is the old `mu4e~main-view' function but without
;; buffer switching at the end.
(defun mu4e~main-view-real (_ignore-auto _noconfirm)
  "The revert buffer function for `mu4e-main-mode'."
  (mu4e~main-view-real-1 'refresh))

(defun mu4e~main-view-real-1 (&optional refresh)
  "Create `mu4e-main-buffer-name' and set it up.
When REFRESH is non nil refresh infos from server."
  (let ((inhibit-read-only t))
    ;; Maybe refresh infos from server.
    (if refresh
        (mu4e~start 'mu4e~main-redraw-buffer)
      (mu4e~main-redraw-buffer))))

(defun mu4e~main-redraw-buffer ()
  (with-current-buffer mu4e-main-buffer-name
    (let ((inhibit-read-only t)
          (pos (point))
          (addrs (mu4e-personal-addresses)))
      (erase-buffer)
      (insert
       "* "
       (propertize "mu4e" 'face 'mu4e-header-key-face)
       (propertize " - mu for emacs version " 'face 'mu4e-title-face)
       (propertize  mu4e-mu-version 'face 'mu4e-header-key-face)
        "\n\n"
       (propertize "  Basics\n\n" 'face 'mu4e-title-face)
       (mu4e~main-action-str
        "\t* [j]ump to some maildir\n" 'mu4e-jump-to-maildir)
       (mu4e~main-action-str
        "\t* enter a [s]earch query\n" 'mu4e-search)
       (mu4e~main-action-str
        "\t* [C]ompose a new message\n" 'mu4e-compose-new)
       "\n"
       (propertize "  Bookmarks\n\n" 'face 'mu4e-title-face)
       (mu4e~main-bookmarks)
       "\n"
       (propertize "  Maildirs\n\n" 'face 'mu4e-title-face)
       (mu4e~main-maildirs)
       "\n"
       (propertize "  Misc\n\n" 'face 'mu4e-title-face)

       (mu4e~main-action-str "\t* [;]Switch context\n" 'mu4e-context-switch)

       (mu4e~main-action-str "\t* [U]pdate email & database\n"
                             'mu4e-update-mail-and-index)

       ;; show the queue functions if `smtpmail-queue-dir' is defined
       (if (file-directory-p smtpmail-queue-dir)
           (mu4e~main-view-queue)
         "")
       "\n"
       (mu4e~main-action-str "\t* [N]ews\n" 'mu4e-news)
       (mu4e~main-action-str "\t* [A]bout mu4e\n" 'mu4e-about)
       (mu4e~main-action-str "\t* [H]elp\n" 'mu4e-display-manual)
       (mu4e~main-action-str "\t* [q]uit\n" 'mu4e-quit)

       "\n"
       (propertize "  Info\n\n" 'face 'mu4e-title-face)
       (mu4e~key-val "database-path" (mu4e-database-path))
       (mu4e~key-val "maildir" (mu4e-root-maildir))
       (mu4e~key-val "in store"
                     (format "%d" (plist-get mu4e~server-props :doccount)) "messages")
       (if mu4e-main-buffer-hide-personal-addresses ""
         (mu4e~key-val "personal addresses" (if addrs (mapconcat #'identity addrs ", "  ) "none"))))

      (if mu4e-main-buffer-hide-personal-addresses ""
        (unless (mu4e-personal-address-p user-mail-address)
          (mu4e-message (concat
                         "Tip: `user-mail-address' ('%s') is not part "
                         "of mu's addresses; add it with 'mu init
                        --my-address='") user-mail-address)))
      (mu4e-main-mode)
      (goto-char pos))))

(defun mu4e~main-view-queue ()
  "Display queue-related actions in the main view."
  (concat
   (mu4e~main-action-str "\t* toggle [m]ail sending mode "
                         'mu4e~main-toggle-mail-sending-mode)
   "(currently "
   (propertize (if smtpmail-queue-mail "queued" "direct")
               'face 'mu4e-header-key-face)
   ")\n"
   (let ((queue-size (mu4e~main-queue-size)))
     (if (zerop queue-size)
         ""
       (mu4e~main-action-str
        (format "\t* [f]lush %s queued %s\n"
                (propertize (int-to-string queue-size)
                            'face 'mu4e-header-key-face)
                (if (> queue-size 1) "mails" "mail"))
        'smtpmail-send-queued-mail)))))

(defun mu4e~main-queue-size ()
  "Return, as an int, the number of emails in the queue."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents (expand-file-name smtpmail-queue-index-file
                                                smtpmail-queue-dir))
        (count-lines (point-min) (point-max)))
    (error 0)))

(defun mu4e~main-view (&optional refresh)
  "Create the mu4e main-view, and switch to it.

When REFRESH is non nil refresh infos from server."
  (let ((buf (get-buffer-create mu4e-main-buffer-name)))
    (if (eq mu4e-split-view 'single-window)
        (if (buffer-live-p (mu4e-get-headers-buffer))
	    (switch-to-buffer (mu4e-get-headers-buffer))
	  (mu4e~main-menu))
      ;; `mu4e~main-view' is called from `mu4e~start', so don't call it
      ;; a second time here i.e. do not refresh unless specified
      ;; explicitly with REFRESH arg.
      (switch-to-buffer buf)
      (with-current-buffer buf
        (mu4e~main-view-real-1 refresh))
      (goto-char (point-min)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interactive functions
;; NEW
;; Toggle mail sending mode without switching
(defun mu4e~main-toggle-mail-sending-mode ()
  "Toggle sending mail mode, either queued or direct."
  (interactive)
  (unless (file-directory-p smtpmail-queue-dir)
    (mu4e-error "`smtpmail-queue-dir' does not exist"))
  (setq smtpmail-queue-mail (not smtpmail-queue-mail))
  (message (concat "Outgoing mail will now be "
                   (if smtpmail-queue-mail "queued" "sent directly")))
  (unless (or (eq mu4e-split-view 'single-window)
              (not (buffer-live-p (get-buffer mu4e-main-buffer-name))))
    (with-current-buffer mu4e-main-buffer-name
      (revert-buffer))))

(defun mu4e~main-menu ()
  "mu4e main view in the minibuffer."
  (interactive)
  (let ((key
         (read-key
          (mu4e-format
           "%s"
           (concat
            (mu4e~main-action-str "[j]ump " 'mu4e-jump-to-maildir)
            (mu4e~main-action-str "[s]earch " 'mu4e-search)
            (mu4e~main-action-str "[C]ompose " 'mu4e-compose-new)
            (mu4e~main-action-str "[b]ookmarks " 'mu4e-headers-search-bookmark)
            (mu4e~main-action-str "[;]Switch context " 'mu4e-context-switch)
            (mu4e~main-action-str "[U]pdate " 'mu4e-update-mail-and-index)
            (mu4e~main-action-str "[N]ews " 'mu4e-news)
            (mu4e~main-action-str "[A]bout " 'mu4e-about)
            (mu4e~main-action-str "[H]elp " 'mu4e-display-manual))))))
    (unless (member key '(?\C-g ?\C-\[))
      (let ((mu4e-command (lookup-key mu4e-main-mode-map (string key) t)))
        (if mu4e-command
            (condition-case err
                (let ((mu4e-hide-index-messages t))
                  (call-interactively mu4e-command))
              (error (when (cadr err) (message (cadr err)))))
          (message (mu4e-format "key %s not bound to a command" (string key))))
        (when (or (not mu4e-command) (eq mu4e-command 'mu4e-context-switch))
          (sit-for 1)
          (mu4e~main-menu))))))

;;; _
(provide 'mu4e-main)
;;; mu4e-main.el ends here
