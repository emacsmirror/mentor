;;; mentor.el --- Frontend for the rTorrent bittorrent client  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2016 Stefan Kangas.
;; Copyright (C) 2011 David Spångberg.

;; Author: Stefan Kangas <stefankangas@gmail.com>
;; Version: 0.2
;; Keywords: comm, processes, bittorrent
;; Package-Requires: ((xml-rpc "1.6.9"))

(defconst mentor-version "0.2"
  "The version of Mentor that you're using.")

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; mentor is a GNU Emacs frontend for the `rTorrent' bittorrent client.  It uses
;; XML-RPC to communicate with rTorrent, and needs rTorrent to be configured
;; accordingly.

;; This project aims to provide a feature complete and highly customizable
;; interface, which will feel familiar to Emacs users.  Key bindings are chosen
;; to be as close to the vanilla rTorrent curses interface as possible.

;; You can find the latest development version of mentor here:
;;
;; http://www.github.com/skangas/mentor

;; Bug reports, comments, and suggestions are welcome! Send them to
;; Stefan Kangas <stefankangas@gmail.com> or report them on GitHub.

;;; Code:
(eval-when-compile
  (require 'cl))
(require 'url-scgi)
(require 'xml-rpc)

(require 'mentor-data)
(require 'mentor-rpc)


;;; Customizable variables

(defgroup mentor nil
  "Emacs frontend for the rTorrent bittorrent client, using XML-RPC."
  :prefix "mentor-"
  :group 'external)

(defcustom mentor-custom-views
  '((1 . "main") (2 . "main") (3 . "started")
    (4 . "stopped") (5 . "complete") (6 . "incomplete")
    (7 . "hashing") (8 . "seeding") (9 . "active"))
  "A list of mappings to bind keys to views.

This takes the form \"(BINDING . VIEWNAME)\" where BINDING is the
key to which the specified VIEWNAME will be bound to."
  :group 'mentor
  :type '(alist :key-type integer :value-type string))

(defcustom mentor-default-view "main"
  "The default view to use when browsing torrents."
  :group 'mentor
  :type 'string)

(defcustom mentor-directory-prefix ""
  "Prefix to use before all directories.

If your rtorrent process is running on a remote host, you could
set this to something like `/ssh:user@example.com:'."
  :group 'mentor
  :type 'string)

(defcustom mentor-highlight-enable nil
  "If non-nil, highlight the line of the current torrent."
  :group 'mentor
  :type 'boolean)

(defcustom mentor-rtorrent-download-directory nil
  "Directory for downloads for background rtorrent."
  :package-version '(mentor . "0.2")
  :group 'mentor
  :type 'string)

(defcustom mentor-rtorrent-keep-session nil
  "If non nil, save session in background rtorrent."
  :package-version '(mentor . "0.2")
  :group 'mentor
  :type 'boolean)

(defcustom mentor-rtorrent-extra-conf nil
  "Extra configuration to add to background rtorrent."
  :package-version '(mentor . "0.2")
  :group 'mentor
  :type 'string)

(defcustom mentor-rtorrent-external-rpc nil
  "URL to an external rtorrent XML-RPC socket.

The default value nil means that we will create our own rtorrent
to run in the background.

For connection using a local socket bound to a file, use
`scgi:///~/.rtorrent-rpc.socket'.  Note that there are triple
slashes in the beginning, as compared to a network connection.

If the connection is over http, which would be the case when
using a web server in front of rtorrent, you would put
`http://HOST[:PORT]/PATH'.

When connecting directly to a scgi_port, use `scgi://HOST:PORT'.
For security reasons, we strongly suggest to use one of the above
methods instead."
  :package-version '(mentor . "0.2")
  :group 'mentor
  :type 'string)

(defcustom mentor-view-columns
  '(((mentor-torrent-get-state) -3 "State")
    ((mentor-torrent-get-progress) -3 "Cmp")
    (name -50 "Name")
    ((mentor-torrent-get-speed-up) -6 "Up")
    ((mentor-torrent-get-speed-down) -6 "Down")
    ((mentor-torrent-get-size) -15 "     Size")
    (message -40 "Message"))
  "A list of all columns to show in mentor view."
  :group 'mentor
  :type '(repeat (list symbol integer string)))


;; Internal variables

(defvar mentor-mode-hook)

(defvar mentor-current-view)

(defvar mentor-home-dir (expand-file-name (convert-standard-filename "mentor/")
                                    user-emacs-directory)
  "Where mentor should put any of its temporary files.")

(defvar mentor-header-line)
(make-variable-buffer-local 'mentor-header-line)

(defvar mentor-rtorrent-client-version)
(make-variable-buffer-local 'mentor-rtorrent-client-version)

(defvar mentor-rtorrent-library-version)
(make-variable-buffer-local 'mentor-rtorrent-library-version)

(defvar mentor-rtorrent-buffer-name "*mentor-term*"
  "Name of the buffer that will run rtorrent process.")

(defvar mentor--rtorrent-session-directory nil)

(defvar mentor-rtorrent-name)
(make-variable-buffer-local 'mentor-rtorrent-name)

(defvar mentor-sort-list '(name))
(make-variable-buffer-local 'mentor-sort-list)

(defvar mentor-last-used-view)
(make-variable-buffer-local 'mentor-last-used-view)

(defvar mentor-last-move-target "~")
(make-variable-buffer-local 'mentor-last-move-target)

(defvar mentor-view-torrent-list nil
  "A list of torrents in given views.")

(defvar mentor-marker-char ?*)

(defvar mentor-re-mark "^[^ \n]")

(defface mentor-highlight-face
  '((((class color) (background light))
     :background "gray13")
    (((class color) (background dark))
     :background "dark goldenrod"))
  "Face for highlighting the current torrent."
  :group 'mentor)

(defface mentor-mark
  '((t :inherit font-lock-warning-face))
  "Face used for marked items."
  :group 'mentor)
(defvar mentor-mark-face 'mentor-mark)

(defface mentor-directory-face
  '((t :inherit font-lock-function-name-face))
  "Face for highlighting directories."
  :group 'mentor)

(defvar mentor-default-item-faces
  '((torrent . nil) (file . nil) (dir . mentor-directory-face))
  "An alist with the default face for item types.")

(defvar mentor-font-lock-keywords
  (list
   ;;
   ;; Mentor marks.
   (list mentor-re-mark '(0 mentor-mark-face)))
  ;; TODO: Highlight marked items

  "Additional expressions to highlight in Mentor mode.")

;; Variables that should be changed by sub-modes

(defvar mentor-sub-mode nil
  "The submode which is currently active.")
(make-variable-buffer-local 'mentor-sub-mode)
(put 'mentor-sub-mode 'permanent-local t)

(defvar mentor-item-update-this-fun)
(make-variable-buffer-local 'mentor-item-update-this-fun)

(defvar mentor-set-priority-fun)
(make-variable-buffer-local 'mentor-set-priority-fun)

(defvar mentor-columns-var)
(make-variable-buffer-local 'mentor-columns-var)


;;; Mentor major-mode

(defvar mentor-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map t)

    ;; torrent list actions
    (define-key map (kbd "DEL") 'mentor-add-torrent)
    (define-key map (kbd "g") 'mentor-update)
    (define-key map (kbd "G") 'mentor-reload)
    (define-key map (kbd "M-g") 'mentor-update-item)

    ;; navigation
    (define-key map (kbd "<up>") 'mentor-previous-item)
    (define-key map (kbd "<down>") 'mentor-next-item)
    (define-key map (kbd "p") 'mentor-previous-item)
    (define-key map (kbd "n") 'mentor-next-item)

    ;; item actions
    (define-key map (kbd "+") 'mentor-increase-priority)
    (define-key map (kbd "-") 'mentor-decrease-priority)

    ;; single torrent actions
    (define-key map (kbd "C") 'mentor-torrent-copy-data)
    (define-key map (kbd "R") 'mentor-torrent-move)
    (define-key map (kbd "b") 'mentor-torrent-set-inital-seeding)
    (define-key map (kbd "e") 'mentor-torrent-recreate-files)
    (define-key map (kbd "o") 'mentor-torrent-change-target-directory)
    (define-key map (kbd "d") 'mentor-torrent-stop)
    (define-key map (kbd "K") 'mentor-torrent-remove-including-files)
    (define-key map (kbd "k") 'mentor-torrent-remove)
    (define-key map (kbd "r") 'mentor-torrent-hash-check)
    (define-key map (kbd "s") 'mentor-torrent-start)
    (define-key map (kbd "x") 'mentor-call-command)

    ;; misc actions
    (define-key map (kbd "RET") 'mentor-torrent-detail-screen)
    (define-key map (kbd "TAB") 'mentor-toggle-item)

    (define-key map (kbd "m") 'mentor-mark)
    (define-key map (kbd "u") 'mentor-unmark)
    (define-key map (kbd "M") 'mentor-mark-all)
    (define-key map (kbd "U") 'mentor-unmark-all)

    (define-key map (kbd "v") 'mentor-view-in-dired)

    (define-key map (kbd "l") 'mentor-load)

    ;; sort functions
    (define-key map (kbd "t c") 'mentor-sort-by-state)
    (define-key map (kbd "t D") 'mentor-sort-by-directory)
    (define-key map (kbd "t d") 'mentor-sort-by-download-speed)
    (define-key map (kbd "t n") 'mentor-sort-by-name)
    (define-key map (kbd "t p") 'mentor-sort-by-property-prompt)
    (define-key map (kbd "t s") 'mentor-sort-by-size)
    (define-key map (kbd "t t") 'mentor-sort-by-tied-file-name)
    (define-key map (kbd "t u") 'mentor-sort-by-upload-speed)
    (define-key map (kbd "q") 'bury-buffer)
    (define-key map (kbd "Q") 'mentor-shutdown)

    ;; view bindings
    (define-key map (kbd "a") 'mentor-add-torrent-to-view)
    (define-key map (kbd "w") 'mentor-switch-to-view)
    (define-key map (kbd "1") (lambda () (interactive) (mentor-switch-to-view 1)))
    (define-key map (kbd "2") (lambda () (interactive) (mentor-switch-to-view 2)))
    (define-key map (kbd "3") (lambda () (interactive) (mentor-switch-to-view 3)))
    (define-key map (kbd "4") (lambda () (interactive) (mentor-switch-to-view 4)))
    (define-key map (kbd "5") (lambda () (interactive) (mentor-switch-to-view 5)))
    (define-key map (kbd "6") (lambda () (interactive) (mentor-switch-to-view 6)))
    (define-key map (kbd "7") (lambda () (interactive) (mentor-switch-to-view 7)))
    (define-key map (kbd "8") (lambda () (interactive) (mentor-switch-to-view 8)))
    (define-key map (kbd "9") (lambda () (interactive) (mentor-switch-to-view 9)))
    map))

(define-derived-mode mentor-mode special-mode "mentor"
  "Major mode for controlling rtorrent from emacs

Type \\[mentor] to start Mentor.

\\{mentor-mode-map}"
  (abbrev-mode 0)
  (auto-fill-mode 0)
  (kill-all-local-variables)
  (setq major-mode 'mentor-mode
        mode-name "mentor"
        buffer-read-only t
        truncate-lines t)
  (set (make-local-variable 'line-move-visual) t)
  (set (make-local-variable 'font-lock-defaults)
     '(mentor-font-lock-keywords t nil nil beginning-of-line))
  (setq mentor-current-view mentor-default-view
        mentor-items (make-hash-table :test 'equal))
  (add-hook 'post-command-hook 'mentor-post-command-hook t t)
  ;;(set (make-local-variable 'revert-buffer-function) 'mentor-revert)
  (use-local-map mentor-mode-map)
  (run-mode-hooks 'mentor-mode-hook))

(defun mentor-rtorrent-create-conf (filename rpc)
  "Generate rtorrent configuration and write to FILENAME.

It will use the RPC argument as value for scgi_local."
  (let ((output
         (concat
          (format "## Autogenerated by mentor.el at %s\n"
                  (format-time-string "%Y-%m-%dT%H:%M:%S"))
          (format "scgi_local = %s\n" rpc)
          (if mentor-rtorrent-download-directory
              (format "directory = %s\n" mentor-rtorrent-download-directory) "")
          (if mentor-rtorrent-keep-session
              (format "session = %s\n" mentor--rtorrent-session-directory) "")
          "xmlrpc_dialect = i8\n"
          "encoding_list = UTF-8\n"
          (if mentor-rtorrent-extra-conf
             (concat "\n## User additions from `mentor-rtorrent-extra-conf':\n"
                     mentor-rtorrent-extra-conf) "") "\n")))
    (with-temp-file filename
      (insert output))))

(defun mentor-rtorrent-already-running (buf rpc)
  (if (and buf (get-buffer buf))
      (condition-case _error
          ;; Already running
          (progn
            (let ((mentor-rtorrent-url rpc))
              (mentor-rpc-command "system.pid"))
            t)
        (error
         ;; Running with problems -- restart it
         (kill-buffer buf)
         nil))
    nil))

(defun mentor-rtorrent-run-in-background ()
  "Start rtorrent in a new buffer."
  (make-directory mentor-home-dir t)
  (if mentor-rtorrent-keep-session
      (make-directory
       (setq mentor--rtorrent-session-directory (expand-file-name
                                           "session" mentor-home-dir)) t))
  (let ((bufname mentor-rtorrent-buffer-name)
        (buf nil)
        (rpc (concat mentor-home-dir "rtorrent.rpc"))
        (conf (expand-file-name (convert-standard-filename "rtorrent.rc")
                                mentor-home-dir)))
    (when (not (mentor-rtorrent-already-running bufname (concat "scgi://" rpc)))
      (mentor-rtorrent-create-conf conf rpc)
      (let ((rtorrent (executable-find "rtorrent")))
        (if (not rtorrent)
            (error "Unable to find rtorrent executable"))
        (get-buffer-create bufname)
        (setq buf (term-ansi-make-term
                   bufname "rtorrent" nil "-n" "-o" (concat "import=" conf))))
      (with-current-buffer buf
        (term-mode)
        (term-char-mode)
        (let (term-escape-char)
          (term-set-escape-char ?\C-x))
        (bury-buffer)))
    (concat "scgi://" rpc)))

(defun mentor-setup-rtorrent ()
  (if mentor-rtorrent-external-rpc
      (setq mentor-rtorrent-url mentor-rtorrent-external-rpc)
    (let ((rpc-url (mentor-rtorrent-run-in-background))
          (rtorrent-started nil)
          (since (float-time)))
      (setq mentor-rtorrent-url rpc-url)
      (message "Waiting for rtorrent to start...")
      (while (not rtorrent-started)
        (condition-case error
            (progn (mentor-rpc-command "system.pid")
                   (setq rtorrent-started t))
          (error
           (if (< (float-time) (+ since 10))
               (sleep-for 0.1)
             (error "mentor: xmlrpc not up after 10 seconds: %s" error))))))))

;;;###autoload
(defun mentor ()
  "Start mentor or switch to mentor buffer."
  (interactive)
  (if (get-buffer "*mentor*")
      ;; Assume that it's set up correctly if it exists
      (switch-to-buffer (get-buffer-create "*mentor*"))
    ;; Otherwise create and set it up
    (switch-to-buffer (get-buffer-create "*mentor*"))
    (mentor-mode)
    (mentor-setup-rtorrent)
    (setq mentor-item-update-this-fun 'mentor-torrent-update-this)
    (setq mentor-set-priority-fun 'mentor-torrent-set-priority-fun)
    (setq mentor-columns-var  'mentor-view-columns)
    (setq mentor-sort-list '((up.rate . t) name))
    (mentor-init-header-line)
    (setq mentor-rtorrent-client-version (mentor-rpc-command "system.client_version")
          mentor-rtorrent-library-version (mentor-rpc-command "system.library_version")
          mentor-rtorrent-name (mentor-rpc-command "session.name"))
    (let* ((pwd-with-trailing-newline (mentor-rpc-command "execute.capture" "" "pwd"))
           (pwd (substring pwd-with-trailing-newline 0 -1)))
      (cd (file-name-as-directory pwd)))
    (mentor-set-view mentor-default-view)
    (when (equal mentor-current-view mentor-last-used-view)
      (setq mentor-last-used-view (mentor-get-custom-view-name 2)))
    (mentor-torrent-data-init)
    (mentor-views-init)
    (mentor-redisplay)
    (goto-char (point-min))))

(defun mentor-post-command-hook ()
  (when mentor-highlight-enable
    (mentor-highlight-torrent)))

(defun mentor-init-header-line ()
  (setq header-line-format
        '(:eval (concat
                 (propertize " " 'display '((space :align-to 1)))
                 (substring mentor-header-line
                            (min (length mentor-header-line)
                                 (window-hscroll)))))))


;;; Mentor items

(defun mentor-between-items ()
  (not (mentor-item-id-at-point)))

(defun mentor-marker-regexp ()
  (concat "^" (regexp-quote (char-to-string mentor-marker-char))))

(defun mentor-repeat-over-lines (arg function)
  "Repeat over lines.

This version skips non-file lines."
  (let ((pos (make-marker)))
    (beginning-of-line)
    (while (and (> arg 0) (not (eobp)))
      (setq arg (1- arg))
      (beginning-of-line)
      (while (and (not (eobp)) (mentor-between-items)) (forward-line 1))
      (save-excursion
        (forward-line 1)
        (move-marker pos (1+ (point))))
      (save-excursion (funcall function))
      ;; Advance to the next line--actually, to the line that *was* next.
      ;; (If FUNCTION inserted some new lines in between, skip them.)
      (goto-char pos))
    (while (and (< arg 0) (not (bobp)))
      (setq arg (1+ arg))
      (forward-line -1)
      (while (and (not (bobp)) (mentor-between-items)) (forward-line -1))
      (beginning-of-line)
      (save-excursion (funcall function)))
    (move-marker pos nil)
    ;; (dired-move-to-filename)
    ))

(defmacro mentor-map-over-marks (body arg &optional _show-progress)
  "Eval BODY with point on each marked line.  Return a list of BODY's results.
If no marked item could be found, execute BODY on the current line.
ARG, if non-nil, specifies the items to use instead of the marked items.
  If ARG is an integer, use the next ARG (or previous -ARG, if
   ARG<0) items.  In that case, point is dragged along.  This is
   so that commands on the next ARG (instead of the marked) items
   can be chained easily.
  For any other non-nil value of ARG, use the current item.
If optional third arg SHOW-PROGRESS evaluates to non-nil,
  redisplay item after it has been processed.
No guarantee is made about the position on the marked line.
  BODY must ensure this itself if it depends on this.
Search starts at the beginning of the buffer, thus the car of the list
  corresponds to the line nearest to the buffer's bottom.  This
  is also true for (positive and negative) integer values of ARG.
BODY should not be too long as it is expanded four times."
  ;;
  ;;Warning: BODY must not add new lines before point - this may cause an
  ;;endless loop.
  ;;This warning should not apply any longer, sk  2-Sep-1991 14:10.
  `(prog1
       (let ((inhibit-read-only t) case-fold-search found results)
         (if ,arg
             (if (integerp ,arg)
                 (progn ;; no save-excursion, want to move point.
                   (mentor-repeat-over-lines
                    ,arg
                    (function (lambda ()
                                ;; (if ,show-progress (sit-for 0))
                                (setq results (cons ,body results)))))
                   (if (< ,arg 0)
                       (nreverse results)
                     results))
               ;; non-nil, non-integer ARG means use current file:
               (list ,body))
           (let ((regexp (mentor-marker-regexp)) next-position)
             (save-excursion
               (goto-char (point-min))
               ;; remember position of next marked file before BODY
               ;; can insert lines before the just found file,
               ;; confusing us by finding the same marked file again
               ;; and again and...
               (setq next-position (and (re-search-forward regexp nil t)
                                        (point-marker))
                     found (not (null next-position)))
               (while next-position
                 (goto-char next-position)
                 ;; (if ,show-progress (sit-for 0))
                 (setq results (cons ,body results))
                 ;; move after last match
                 (goto-char next-position)
                 (forward-line 1)
                 (set-marker next-position nil)
                 (setq next-position (and (re-search-forward regexp nil t)
                                          (point-marker)))))
             (if found
                 results
               (list ,body)))))))
     ;; ;; save-excursion loses, again
     ;; (dired-move-to-filename)))

(defun mentor-get-marked-items (&optional arg)
  "Return the marked items' names as list of strings.
The list is in the same order as the buffer, that is, the car is the
  first marked file.
Optional argument ARG, if non-nil, specifies items near
 point instead of marked items.  It usually comes from the prefix
 argument.
  If ARG is an integer, use the next ARG items.
  Any other non-nil value means to use the current file instead."
  (save-excursion
    (nreverse
     (mentor-map-over-marks
      (mentor-item-get-name (mentor-get-item-at-point))
      arg))))

;; Based on `dired-mark-pop-up'
(defun mentor-mark-pop-up (bufname items function &rest args)
  "Return FUNCTION's result on ARGS after showing which items are marked.
Displays the file names in a window showing a buffer named
BUFNAME; the default name being \" *Marked Items*\".  The window
is not shown if there is just one item.

ITEMS is the list of marked items.

FUNCTION should not manipulate items, just read input
(an argument or confirmation)."
  (if (= (length items) 1)
      (apply function args)
    (let ((buffer (get-buffer-create (or bufname " *Marked Items*"))))
      (with-current-buffer buffer
        (with-current-buffer-window
         buffer       
         (cons 'display-buffer-below-selected
               '((window-height . fit-window-to-buffer)))
         #'(lambda (window _value)
             (with-selected-window window
               (unwind-protect
                   (apply function args)
                 (when (window-live-p window)
                   (quit-restore-window window 'kill)))))
         (erase-buffer)
         (completion--insert-strings items))))))

(defun mentor-mark-prompt (arg items)
  "Return a string suitable for use in a mentor prompt.
ARG is normally the prefix argument for the calling command.
ITEMS should be a list of item names."
  (let ((count (length items)))
    (if (= count 1)
	(car items)
      ;; more than 1 item:
      (if (integerp arg)
	  (format "[%s %d items]" (if (> arg 0) "next" "previous") count)
	(format "[%d items]" count)))))

(defun mentor-mark-confirm (desc arg)
  (let ((items (mentor-get-marked-items arg)))
    (mentor-mark-pop-up nil items (function y-or-n-p)
                  (concat desc " "
                          (mentor-mark-prompt arg items) "? "))))


;;; Getting torrent data

(defun mentor-torrent-data-init ()
  "Initialize torrent data from rtorrent.

All torrent information will be re-fetched, making this an
expensive operation."
  (message "Initializing torrent data...")
  (mentor-rpc-d.multicall mentor-rpc-d-methods t)
  (mentor-views-update-views)
  (message "Initializing torrent data... DONE"))

(defun mentor-torrent-data-update-all ()
  (message "Updating torrent data...")
  (condition-case _err
      (progn
        (mentor-rpc-d.multicall mentor-volatile-rpc-d-methods)
        (message "Updating torrent data...DONE"))
    (mentor-need-init
     (mentor-torrent-data-init))))

(defun mentor-torrent-update-this ()
  (let* ((tor (mentor-get-item-at-point))
         (hash (mentor-item-property 'hash tor))
         (methods mentor-volatile-rpc-d-methods)
         (values (mapcar
                  (lambda (method)
                    (mentor-rpc-command method hash))
                  methods)))
    (mentor-torrent-update-from methods values)
    (mentor-redisplay-torrent)))


;;; Main torrent view

(defmacro mentor-keep-position (&rest body)
  "Keep the current position."
  `(let ((kept-torrent-id (mentor-item-id-at-point))
         (kept-point (point)))
     ,@body
     (if kept-torrent-id
         (condition-case _err
             (mentor-goto-torrent kept-torrent-id)
           (mentor-missing-torrent
            (goto-char kept-point)))
       (goto-char kept-point))))

(defun mentor-insert-torrent (id)
  (let* ((item (mentor-get-item id))
         (text (mentor-process-view-columns item mentor-view-columns))
         (marked (mentor-item-marked item)))
    (insert (propertize text
                        'marked marked
                        'field id
                        'collapsed t
                        'type 'torrent) "\n")
    (when marked
      (save-excursion
        (mentor-previous-item)
        (mentor-mark)))))

(defun mentor-insert-torrents ()
  (let ((tor-ids (cdr (assoc (intern mentor-current-view)
                             mentor-view-torrent-list))))
    (dolist (id tor-ids)
      (mentor-insert-torrent id))))

(defun mentor-redisplay-torrent ()
  (let ((inhibit-read-only t)
        (id (mentor-item-id-at-point)))
    (mentor-delete-item-from-buffer (point))
    (mentor-insert-torrent id)
    (mentor-previous-item)))

(defun mentor-process-columns-helper (cols lenfun strfun)
  (mapcar (lambda (column)
            (let* ((len (funcall lenfun column))
                   (str (funcall strfun column)))
              (concat (mentor-enforce-length str len) " ")))
          cols))

(defun mentor-process-view-header-columns (cols)
  (apply 'concat
         (mentor-process-columns-helper
          cols
          (lambda (col) (or (cadddr col)
                            (cadr col)))
          (lambda (col) (caddr col)))))

(defun mentor-process-view-columns (item cols)
  (apply 'concat " "
         (mentor-process-columns-helper
          cols
          (lambda (col) (cadr col))
          (lambda (col)
            (let ((prop (car col)))
              (if (not prop)
                  ""
                (if (listp prop)
                    (apply (car prop) item (cdr prop))
                  (let ((text (mentor-item-property prop item)))
                    text))))))))

(defun mentor-reload-header-line ()
  (setq mentor-header-line
        (mentor-process-view-header-columns (eval mentor-columns-var))))

(defvar mentor-highlight-overlay nil)
(make-variable-buffer-local 'mentor-highlight-overlay)

(defvar mentor-highlighted-torrent nil)
(make-variable-buffer-local 'mentor-highlighted-torrent)

(defun mentor-highlight-torrent ()
  (let ((cur (mentor-item-id-at-point)))
    (when (not mentor-highlight-overlay)
      (setq mentor-highlight-overlay (make-overlay 1 10))
      (overlay-put mentor-highlight-overlay
                   'face 'mentor-highlight-face))
    (if cur
        (when (not (equal cur mentor-highlighted-torrent))
          (setq mentor-highlighted-torrent cur)
          (move-overlay mentor-highlight-overlay
                        (mentor-get-item-beginning)
                        (mentor-get-item-end)
                        (current-buffer)))
      (delete-overlay mentor-highlight-overlay)
      (setq mentor-highlighted-torrent nil))))


;;; Sorting

(defun mentor-do-sort ()
  (mentor-keep-position
   (goto-char (point-min))
   (save-excursion
     (let ((sort-fold-case t)
           (inhibit-read-only t))
       (sort-subr nil
                  (lambda () (ignore-errors (mentor-next-item 1 t)))
                  (lambda () (ignore-errors (mentor-end-of-item)))
                  (lambda ()
                    (let ((item (mentor-get-item-at-point)))
                      (mapcar* (lambda (p)
                                 (let ((prop (or (and (listp p) (car p)) p)))
                                  (mentor-item-property prop item)))
                               mentor-sort-list)))
                  nil
                  (lambda (a b)
                    (mentor-cmp-properties a b mentor-sort-list)))))))

(defun mentor-cmp-properties (x y &optional props)
  (let* ((a (car x))
         (b (car y))
         (reverse (cdr-safe (car props)))
         (cmp (if (stringp a)
                  (if reverse (not (string< a b)) (string< a b))
                (if reverse (> a b) (< a b)))))
    (when (and (not cmp) (equal a b) (> (length props) 1))
      (setq cmp (mentor-cmp-properties (cdr x) (cdr y) (cdr props))))
    cmp))

(defun mentor-sort (&optional property reverse append)
  "Sort the mentor torrent buffer.
Defaults to sorting according to `mentor-sort-list'.

PROPERTY gives according to which property the torrents should be
sorted.

If REVERSE is non-nil, the result of the sort is reversed.

When APPEND is non-nil, instead of sorting directly, add the
result to the end of `mentor-sort-list'.  This makes it possible
to sort according to several properties."
  (when property
    (let ((elem (cons property reverse)))
      (if append
          (add-to-list 'mentor-sort-list elem t)
        (setq mentor-sort-list (list elem)))))
  (mentor-do-sort))

(defun mentor-sort-by-directory (append)
  (interactive "P")
  (mentor-sort 'directory nil append))

(defun mentor-sort-by-download-speed (append)
  (interactive "P")
  (mentor-sort 'down.rate t append))

(defun mentor-sort-by-name (append)
  (interactive "P")
  (mentor-sort 'name nil append))

(defun mentor-sort-by-state (append)
  (interactive "P")
  (mentor-sort 'state nil append))

(defun mentor-sort-by-tied-file-name (append)
  (interactive "P")
  (mentor-sort 'tied_to_file nil append))

(defun mentor-sort-by-size (append)
  (interactive "P")
  (mentor-sort 'size_bytes t append))

(defun mentor-sort-by-upload-speed (append)
  (interactive "P")
  (mentor-sort 'up.rate t append))


;;; Navigation

(defmacro mentor-while-same-item (condition skip-blanks &rest body)
  `(let* ((item (mentor-item-id-at-point)))
     (while (and ,condition
                 (or (and ,skip-blanks
                          (not (mentor-item-id-at-point)))
                     (equal item (mentor-item-id-at-point))))
       ,@body)))

(defun mentor-beginning-of-item ()
  "Goto the beginning of the item at point.

If the item at point has an item-start property defined and
REAL-START is nil goto that point.  Otherwise goto the real start
point."
  (interactive)
  (let ((start (or (get-text-property (point) 'item-start)
                   (field-beginning nil nil (point-at-bol)))))
    (when start
      (goto-char start))))

(defun mentor-end-of-item ()
  "Goto the end of the item at point."
  (interactive)
  (ignore-errors (mentor-next-item 1 t))
  (mentor-while-same-item (not (bobp)) nil (backward-char)))

(defun mentor-get-item-beginning ()
  (save-excursion
    (mentor-beginning-of-item)
    (point)))

(defun mentor-get-item-end ()
  (save-excursion
    (mentor-end-of-item)
    (point)))

(defun mentor-next-item (&optional arg no-wrap)
  "Go to the next item."
  (interactive "P")
  (let* ((arg (or arg 1))
         (reverse (< arg 0))
         (i (abs arg))
         (done nil))
    (while (and (> i 0))
      (decf i)
      (setq done nil)
      (mentor-while-same-item (not done) t
       (let ((at-buf-limit (if reverse (bobp) (eobp)))
             (step (if reverse -1 1)))
         (cond ((not at-buf-limit)
                (forward-line step))
               (no-wrap
                (signal (if reverse 'beginning-of-buffer 'end-of-buffer) t))
               (t
                (goto-char (if reverse (point-max) (point-min)))
                (when (not (mentor-get-item-type))
                  (while (and (not (mentor-item-id-at-point))
                              (if reverse (bobp) (eobp)))
                    (forward-line step)))
                (setq done t))))))))

(defun mentor-previous-item (&optional arg no-wrap)
  "Go to previous item."
  (interactive "P")
  (mentor-next-item (- 0 (or arg 1)) no-wrap))

(put 'mentor-missing-torrent
     'error-conditions
     '(error mentor-error mentor-missing-torrent))

(defun mentor-delete-item-from-buffer (item)
  (let ((inhibit-read-only t))
    (goto-char item)
    (delete-region (mentor-get-item-beginning)
                   (+ 1 (mentor-get-item-end)))))

(defun mentor-goto-torrent (id)
  (let ((pos (save-excursion
               (goto-char (point-min))
               (while (and (not (equal id (mentor-item-id-at-point)))
                           (not (= (point) (point-max))))
                 (mentor-next-item 1 t))
               (point))))
    (if (not (= pos (point-max)))
        (goto-char pos)
      (signal 'mentor-missing-torrent `("No such torrent" ,id)))))

(defun mentor-toggle-item ()
  (interactive)
  (let ((type (mentor-get-item-type)))
    (cond ((eq type 'dir)
           (mentor-toggle-file (get-text-property (point) 'file))))))


;;; Interactive item commands

(defun mentor-item-update-this ()
  (funcall mentor-item-update-this-fun))

(defun mentor-set-priority (val)
  (setq val (or val 1))
  (apply 'mentor-rpc-command (funcall mentor-set-priority-fun val)))

(defun mentor-decrease-priority ()
  (interactive)
  (mentor-set-priority -1)
  (mentor-item-update-this))

(defun mentor-increase-priority ()
  (interactive)
  (mentor-set-priority 1)
  (mentor-item-update-this))

(defun mentor-update-item (&optional arg)
  (interactive "P")
  (mentor-map-over-marks (mentor-item-update-this)
   arg))

(defun mentor-mark (&optional arg)
  "Mark the current (or next ARG) items.

Use \\[mentor-unmark-all-files] to remove all marks
and \\[mentor-unmark] on a subdir to remove the marks in
this subdir."
  (interactive "P")
  (let ((inhibit-read-only t))
    (mentor-repeat-over-lines
     (prefix-numeric-value arg)
     (function (lambda ()
                 ;; insert at point-at-bol + 1 to inherit all properties
                 (goto-char (1+ (point-at-bol)))
                 (insert-and-inherit mentor-marker-char)
                 (delete-region (point-at-bol) (+ 1 (point-at-bol))))))))

(defun mentor-unmark (&optional arg)
  "Unmark the current (or next ARG) items."
  (interactive "P")
  (let ((mentor-marker-char ?\040))
    (mentor-mark arg)))

(defun mentor-mark-all ()
  "Mark all visible items except directories."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (mentor-mark))))

(defun mentor-unmark-all ()
  "Unmark all visible items."
  (interactive)
  (mentor-map-over-marks
   (mentor-unmark)
   nil))


;;; Interactive torrent commands

;; TODO: Report how it went, including failures.
(defun mentor-delete-file (file)
  (let ((dired-recursive-deletes nil))
    (condition-case _err
        (dired-delete-file file)
      (file-error nil))))

(defun mentor-get-old-torrent-path (tor)
  (let ((path (or (mentor-item-property 'base_path tor)
                  (and (= (mentor-item-property 'bytes_done tor) 0)
                       (mentor-item-property 'directory tor))))
        (is-multi-file (= 1 (mentor-item-property 'is_multi_file tor))))
    (when (not path)
      (error "Unable to get path for torrent"))
    (if (or is-multi-file (not (file-directory-p path)))
        (substring (directory-file-name path)
                   0 (- (length (file-name-nondirectory path))))
      path)))

(defun mentor-get-new-torrent-path (tor)
  "Helper function for `mentor-copy-torrent-data' and
`mentor-move-torrent-data'"
  (let* ((old (mentor-get-old-torrent-path tor))
         (old-prefixed (concat mentor-directory-prefix old))
         (new (read-file-name "New path: " old-prefixed nil t)))
    (when (string-equal old new)
      (error "Source and destination are the same"))
    (when (not (condition-case _err
                   (mentor-rpc-command "execute2" "" "ls" "-d" new)
                 (error nil)))
      (error "No such file or directory: %s" new))
    new))

(defun mentor-add-torrent (prefix)
  "Load and start downloading a torrent file or magnet URL.

If PREFIX is set, the added torrent will not be started after
being added."
  (interactive "P")
  (let* ((is-torrent-p (lambda (x)
                         (or (and (not (string-match "^\\." x))
                                  (file-directory-p x))
                             (string-match "\.torrent$" x))))
         (file (read-file-name "Add torrent: " nil nil
                               nil nil is-torrent-p)))
    (if (string-match "^magnet:" file)
        (mentor-c-load file prefix)
      (mentor-c-load-raw file prefix)))
  (mentor-update))

(defun mentor-load (prefix file)
  "Load a file or url adding it to the current torrents if
successful.  Unlike ``mentor-add-torrent'' this would work with
files on a remote host.  If prefix is set the added torrent is
started after being added."
  (interactive "P\nMMentor load: ")
  (mentor-c-load file prefix))

(defun mentor-call-command (&optional cmd)
  (interactive "MEnter command: ")
  (apply 'mentor-rpc-command (split-string cmd)))

(defun mentor-download-get-file-list (tor)
  (let ((files (mentor-item-property 'files tor)))
    (when (not (cdr-safe files))
      (progn
        (message "Receiving file list...")
        (setq files (mentor-rpc-command
                     "f.multicall" (mentor-d-get-hash tor)
                     "" "f.path_components="))
        (mentor-item-set-property 'files files tor)))
    files))

(defun mentor--do-remove-torrent-files (tor files)
  (let* ((base-path (mentor-d-get-base-path))
         dirs)
    (if (mentor-d-is-multi-file tor)        
        (progn
          (dolist (file files)
            (let* ((file (concat base-path "/" (caar file)))
                   (dir (file-name-directory file)))
              (mentor-delete-file file)
              (setq dirs (adjoin dir dirs :test 'equal))))
          (setq dirs (sort dirs (lambda (a b) (not (string< a b)))))
          (dolist (dir dirs)
            (mentor-delete-file dir)))
      (mentor-delete-file base-path))))

(defun mentor--torrent-remove-helper (remove-files &optional arg)
  (when (mentor-mark-confirm
         (or (and remove-files "Remove including data")
             "Remove")
         arg)
    (dolist (item
             (mentor-map-over-marks
              (progn
                (let* ((tor (mentor-get-item-at-point))
                       (files (and remove-files
                                   (mentor-download-get-file-list tor))))
                  (mentor-d-erase tor)
                  (when remove-files
                    (mentor--do-remove-torrent-files tor files))
                  (mentor-view-torrent-list-delete-all tor)
                  (remhash (mentor-d-get-local-id tor) mentor-items)
                  (point)))
              arg))
      (mentor-delete-item-from-buffer item))))

(defun mentor-torrent-remove (&optional arg)
  (interactive "P")
  (mentor--torrent-remove-helper nil arg))

(defun mentor-torrent-remove-including-files (&optional arg)
  (interactive "P")
  (mentor--torrent-remove-helper t arg))

(defun mentor-get-new-path (&optional prompt old)
  (let* ((old (concat mentor-directory-prefix
                      (or old mentor-last-move-target)))
         (prompt (or prompt "New path: "))
         (new (read-file-name prompt old nil t)))
    (if (condition-case _err
            (mentor-rpc-command "execute2" "" "ls" "-d" new)
          (error nil))
        (setq mentor-last-move-target new)
      (error (concat "No such file or directory: " new)))))

;; TODO: Sort out the "copied" and "moved" messages below to give a summary
;; instead of just the last file.

(defun mentor-torrent-copy-data (&optional arg)
  (interactive "P")
  (let* ((items (mentor-get-marked-items))
         (prompt (concat "Copy " (mentor-mark-prompt arg items) " to: "))
         (new (mentor-mark-pop-up nil items 'mentor-get-new-path prompt)))
   (mentor-map-over-marks
    (let* ((old (mentor-d-get-base-path)))
      (when (and (not (null old))
                 (file-exists-p old))
        (mentor-execute "cp" "-Rn" old new))
      (message "Copied %s to %s" (mentor-d-get-name) new)
      (mentor-redisplay-torrent))
    arg)))

(defun mentor-torrent-move (&optional no-move arg)
  (interactive "P")
  (let* ((items (mentor-get-marked-items))
         (verbstr (or (and no-move "Change directory of ") "Move "))
         (prompt (concat verbstr (mentor-mark-prompt arg items) " to: "))
         (new (mentor-mark-pop-up nil items 'mentor-get-new-path prompt)))
    (mentor-map-over-marks
     (let* ((old (or (and no-move (mentor-d-get-directory))
                     (mentor-d-get-base-path)))
            (was-started (mentor-d-is-active)))
       (when (not no-move)
         (when (null old)
           (error "Torrent has no base path"))
         ;; FIXME: Should work also on remote host, i.e. use rpc "execute2"
         ;; to look for the file.
         (when (not (file-exists-p old))
           (error (concat "Download base path %s does not exist\n"
                          "Try `mentor-torrent-change-target-directory'")
                  old))
         (let ((target (concat new (file-name-nondirectory old))))
          (when (file-exists-p target)
            (error "Destination already exists: %s" target)))
         (when (and (not (mentor-d-is-multi-file))
                    (file-directory-p old))
           (error "Moving single torrent, base_path is a directory. This is probably a bug.")))
       (if (not (equal (file-name-directory old) new))
           (progn
             (when was-started
               (mentor-d-stop))
             (if (not no-move)
                 (mentor-execute "mv" "-u" old new))
             (mentor-d-set-directory new)
             (when was-started
               (mentor-d-start))
             (mentor-torrent-update-this)
             (if no-move
                 (message "Changed %s target directory to %s" (mentor-d-get-name) new)
               (message "Moved %s to %s" (mentor-d-get-name) new)))
         (message "Skipping %s since it is already in %s"
                  (mentor-d-get-name) new))
       (mentor-redisplay-torrent))
     arg)))

(defun mentor-torrent-change-target-directory (&optional arg)
  "Change torrents target directory without moving data."
  (interactive "P")
  (mentor-torrent-move t arg))

(defun mentor-torrent-hash-check (&optional arg)
  (interactive "P")
  (mentor-map-over-marks
   (progn
     (let ((tor (mentor-get-item-at-point)))
       (mentor-rpc-command "d.check_hash" (mentor-item-property 'hash tor))
       (mentor-item-set-property 'hashing 1 tor)
       (mentor-item-set-property 'is_open 1 tor)
       (mentor-torrent-update-this)))
   arg))

(defun mentor-torrent-pause (&optional arg)
  "Pause torrent. This is probably not what you want, use
`mentor-torrent-stop' instead."
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-rpc-command "d.pause" (mentor-item-property 'hash))
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-resume (&optional arg)
  "Resume torrent. This is probably not what you want, use
`mentor-torrent-start' instead."
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-rpc-command "d.resume" (mentor-item-property 'hash))
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-start (&optional arg)
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-d-start)
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-stop (&optional arg)
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-d-stop)
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-open (&optional arg)
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-rpc-command "d.open" (mentor-item-property 'hash))
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-close (&optional arg)
  (interactive "P")
  (mentor-map-over-marks
   (progn (mentor-rpc-command "d.close" (mentor-item-property 'hash))
          (mentor-torrent-update-this))
   arg))

(defun mentor-torrent-recreate-files ()
  "Set the 'create/resize queued' flags on all files in a torrent."
  (interactive)
  (message "TODO: mentor-torrent-recreate-files"))

(defun mentor-torrent-set-inital-seeding ()
  (interactive)
  (message "TODO: mentor-torrent-set-inital-seeding"))

(defun mentor-view-in-dired ()
  (interactive)
  (let* ((tor (mentor-get-item-at-point))
         (is-multi-file (= 1 (mentor-item-property 'is_multi_file tor)))
         (path (mentor-item-property 'base_path tor))
         (path2 (and path (if is-multi-file path (file-name-directory path)))))
    (if path2
        (progn
          (find-file path2)
          (when (not is-multi-file)
            (dired-goto-file path)))
      (message "Torrent does not have a base path"))))

(defun mentor-update ()
  "Update all torrents and redisplay."
  (interactive)
  (cond ((eq mentor-sub-mode 'file-details) (mentor-files-update))
        ((not mentor-sub-mode)
         (mentor-keep-position
          (when (mentor-views-is-custom-view mentor-current-view)
            (mentor-views-update-filter mentor-current-view))
          (mentor-torrent-data-update-all)
          (mentor-redisplay)))))

(defun mentor-reload ()
  "Re-initialize all torrents and redisplay."
  (interactive)
  (cond ((eq mentor-sub-mode 'file-details) (mentor-files-update t))
        ((not mentor-sub-mode)
         (mentor-keep-position
          (when (mentor-views-is-custom-view mentor-current-view)
            (mentor-views-update-filter mentor-current-view))
          (setq mentor-items (make-hash-table :test 'equal))
          (mentor-torrent-data-init)
          (mentor-redisplay)))))

(defun mentor-redisplay ()
  "Redisplay the mentor torrent view buffer."
  (interactive)
  (mentor-reload-header-line)
  (when (equal major-mode 'mentor-mode)
    (save-excursion
      (let ((inhibit-read-only t))
        (erase-buffer)
        (mentor-insert-torrents)
        (mentor-sort)
        (goto-char (point-max))
        (insert "\n mentor " mentor-version " - rTorrent "
                mentor-rtorrent-client-version "/"
                mentor-rtorrent-library-version
                " (" mentor-rtorrent-name ")\n")))))

(defun mentor-shutdown-rtorrent ()
  "Exit mentor, killing any running rtorrent processes."
  (interactive)
  (when (y-or-n-p "Really shutdown mentor?")
    (kill-buffer (current-buffer))
    ;; system.shutdown currently does nothing.  Oh, well.
    ;; (mentor-rpc-command "system.shutdown")
    ;; TODO: Clean shutdown...
    (ignore-errors
     (kill-buffer mentor-rtorrent-buffer-name))))


;;; Torrent views

(defun mentor-view-torrent-list-add (tor)
  (let* ((id (mentor-item-property 'local_id tor))
         (view (intern mentor-current-view))
         (list (assq view mentor-view-torrent-list)))
    (push id (cdr list))))

(defun mentor-view-torrent-list-clear ()
  (let ((view (intern mentor-current-view)))
    (setq mentor-view-torrent-list
          (assq-delete-all view mentor-view-torrent-list))
    (setq mentor-view-torrent-list
          (cons (list view) mentor-view-torrent-list))))

(defun mentor-view-torrent-list-delete (&optional tor view)
  (let* ((view (or view (intern mentor-current-view)))
         (list (assq view mentor-view-torrent-list)))
    (delete (mentor-d-get-local-id tor) list)))

(defun mentor-view-torrent-list-delete-all (&optional tor)
  (dolist (view mentor-view-torrent-list)
    (mentor-view-torrent-list-delete tor (car view))))


;;; Get torrent data from rtorrent

(defun mentor-torrent-update-from (methods values &optional is-init)
  (let ((tor (mentor-torrent-create
              (mapcar* (lambda (method value)
                         (cons (mentor-rpc-method-to-property method)
                               (mentor-rpc-value-to-real-value method value)))
                       methods values))))
    (mentor-torrent-update tor is-init)
    (mentor-view-torrent-list-add tor)))

(defun mentor-torrent-get-progress (torrent)
  (let* ((donev (mentor-item-property 'bytes_done torrent))
         (totalv (mentor-item-property 'size_bytes torrent))
         (done (abs (or donev 0)))
         (total (abs (or totalv 1)))
         (percent (* 100 (/ (+ 0.0 done) total))))
    (if (= (truncate percent) 100)
        ""
      (format "%d%%" percent))))

;; TODO show an "I" for incomplete torrents
(defun mentor-torrent-get-state (tor)
  (let* ((h (mentor-item-property 'hashing tor))
         (a (mentor-item-property 'is_active tor))
         (o (mentor-item-property 'is_open tor))
         (first-char (if (> h 0) "H" (if (= a 1) " " "S")))
         (second-char (if (= o 1) " " "C")))
    (concat first-char second-char)))

(defun mentor-torrent-get-speed-down (torrent)
  (mentor-bytes-to-kilobytes
   (mentor-item-property 'down.rate torrent)))

(defun mentor-torrent-get-speed-up (torrent)
  (mentor-bytes-to-kilobytes
   (mentor-item-property 'up.rate torrent)))

(defun mentor-torrent-get-size (torrent)
  (let ((done (mentor-item-property 'bytes_done torrent))
        (total (mentor-item-property 'size_bytes torrent)))
    (if (= done total)
        (format "         %-.6s" (mentor-bytes-to-human total))
      (format "%6s / %-6s"
              (mentor-bytes-to-human done)
              (mentor-bytes-to-human total)))))

(defun mentor-torrent-get-size-done (torrent)
  (mentor-bytes-to-human
   (mentor-item-property 'bytes_done torrent)))

(defun mentor-torrent-get-size-total (torrent)
  (mentor-bytes-to-human
   (mentor-item-property 'size_bytes torrent)))

(defun mentor-torrent-has-view (tor view)
  "Returns t if the torrent has the specified view."
  (member view (mentor-torrent-get-views tor)))

(defun mentor-torrent-get-views (tor)
  (mentor-item-property 'views tor))

(defun mentor-torrent-get-prio (tor)
  (let ((prio (mentor-item-property 'priority tor)))
    (cond ((= 0 prio) "off")
          ((= 1 prio) "low")
          ((= 2 prio) "")
          ((= 3 prio) "hig"))))

(defun mentor-torrent-set-priority-fun (val)
  (let ((hash (mentor-item-property 'hash))
        (prio (mentor-item-property 'priority)))
    (list "d.priority.set" hash (mentor-limit-num (+ prio val) 0 3))))


;;; View functions

(defvar mentor-torrent-views)
(make-variable-buffer-local 'mentor-torrent-views)

(defconst mentor-custom-view-prefix "mentor-"
  "The string to add to the view name before adding it to
  rtorrent.")

(defun mentor-add-torrent-to-view (view)
  (interactive
   (list (mentor-prompt-complete "Add torrent to view: "
                                 (remove-if-not 'mentor-views-is-custom-view
                                                mentor-torrent-views)
                                 nil mentor-current-view)))
  (let ((tor (mentor-get-item-at-point)))
   (when (not (mentor-views-is-custom-view view))
     (setq view (concat mentor-custom-view-prefix view)))
   (if (not (mentor-views-valid-view-name view))
       (message "Not a valid name for a view!")
     (if (or (mentor-views-is-view-defined view)
             (when (y-or-n-p (concat "View " view " was not found. Create it? "))
               (mentor-views-add view) t))
         (mentor-rpc-command "d.views.push_back_unique"
                             (mentor-item-property 'hash tor) view)
       (message "Nothing done")))))

(defconst mentor-torrent-default-views
  '("main" "name" "started" "stopped" "complete"
    "incomplete" "hashing" "seeding" "active"))

;; TODO find out what a valid name is in rtorrent
(defun mentor-views-valid-view-name (_name)
  t)

(defun mentor-set-view (new)
  (setq mentor-last-used-view (or mentor-current-view
                                  mentor-default-view))
  (setq mentor-current-view new)
  (setq mode-line-buffer-identification (concat "*mentor* " mentor-current-view)))

(defun mentor-switch-to-view (&optional new)
  (interactive)
  (when (null new)
    (setq new (mentor-prompt-complete
               "Show view: " mentor-torrent-views
               1 mentor-last-used-view)))
  (when (numberp new)
    (setq new (mentor-get-custom-view-name new)))
  (when (not (equal new mentor-current-view))
    (mentor-set-view new)
    (mentor-update)
    (message "Showing view: %s" mentor-current-view)))

(defun mentor-views-add (view)
  "Adds the specified view to rtorrents \"view_list\" and sets
the new views view_filter. SHOULD BE USED WITH CARE! Atleast in
rtorrent 0.8.6, rtorrent crashes if you try to add the same view
twice!"
  (mentor-rpc-command "view.add" view)
  (setq mentor-torrent-views (cons view mentor-torrent-views))
  (mentor-views-update-filter view))

(defun mentor-views-init ()
  "Initialize views.
Gets all unique views from torrents, adds all views not
already in view_list and sets all new view_filters."
  ;; should always update the views before potentially adding new ones
  (mentor-views-update-views))

;; FIXME: this was part of mentor-views-init, but why?
  ;; (maphash
  ;;  (lambda (id torrent)
  ;;    (mapcar (lambda (view)
  ;;              (when (and (mentor-views-is-custom-view view)
  ;;                         (not (mentor-views-is-view-defined view)))
  ;;                (mentor-views-add view)))
  ;;            (cdr (assoc 'views torrent))))
  ;;  mentor-items))

(defun mentor-views-update-views ()
  "Updates the view list with all views defined by rtorrent."
  (setq mentor-torrent-views (mentor-rpc-command "view.list")))

(defun mentor-views-update-filter (view)
  "Updates the view_filter for the specified view. You need to do
this everytime you add/remove a torrent to a view since
rtorrent (atleast as of 0.8.6) does not add/remove new torrents
to a view unless the filter is updated."
  (mentor-rpc-command "view.filter" view
                      (concat "d.views.has=" view)))

(defun mentor-views-update-filters ()
  "Updates all view_filters for custom views in rtorrent."
  (mapc (lambda (view)
          (when (mentor-views-is-custom-view  view)
            (mentor-views-update-filter view)))
        mentor-torrent-views))

(defun mentor-views-is-view-defined (view)
  (member view mentor-torrent-views))

(defun mentor-views-is-custom-view (view)
  ;;(not (member view mentor-torrent-default-views)))
  (string-match (concat "^" mentor-custom-view-prefix) view))

(defun mentor-views-is-default-view (view)
  (member view mentor-torrent-default-views))


;;; Torrent details screen

(defvar mentor-selected-torrent nil)
(make-variable-buffer-local 'mentor-selected-torrent)
(put 'mentor-selected-torrent 'permanent-local t)

(defvar mentor-selected-torrent-info nil)
(make-variable-buffer-local 'mentor-selected-torrent)
(put 'mentor-selected-torrent 'permanent-local t)

(defvar mentor-torrent-details-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "N") 'mentor-details-next-directory)
    (define-key map (kbd "P") 'mentor-details-previous-directory)
    map)
  "Keymap used in `mentor-torrent-details-mode'.")

(defconst mentor-volatile-rpc-f-methods
  '("f.priority" "f.completed_chunks" "f.size_chunks"))

(define-minor-mode mentor-torrent-details-mode
  "Minor mode for managing a torrent in mentor."
  :group mentor
  :init-value nil
  :lighter nil
  :keymap mentor-torrent-details-mode-map)

(defun mentor-file-at-point ()
  (get-text-property (point) 'file))

(defun mentor-file-is-dir (file)
  (and (mentor-file-p file) (eq 'dir (mentor-file-type file))))

(defun mentor-file-prio-string (file)
  (let ((prio (mentor-file-priority file)))
    (cond ((eq prio 0) "off")
          ((eq prio 1) "")
          ((eq prio 2) "hig"))))

(defun mentor-file-progress (file)
  (let* ((done (mentor-file-completed_chunks file))
         (size (mentor-file-size_chunks file)))
    (format "%d" (* 100 (/ (+ 0.0 done) size)))))

(defun mentor-file-readable-size (file)
  (let* ((chunk-size (mentor-item-property
                      'chunk_size mentor-selected-torrent)))
    (mentor-bytes-to-human
     (* chunk-size (mentor-file-size_chunks file)))))

(defun mentor-file-set-priority-fun (val)
  (let* ((file (mentor-file-at-point))
         (id   (mentor-file-id file))
         (prio (mentor-file-priority file))
         (hash (mentor-item-property 'hash mentor-selected-torrent)))
    (when (not (mentor-file-is-dir file))
      (list "f.priority.set" hash id (mentor-limit-num (+ prio val) 0 2)))))

(defun mentor-toggle-file (file)
  (interactive)
  (let ((start-point (point)))
    (when (mentor-file-is-dir file)
      (setf (mentor-file-show file)
            (if (mentor-file-show file)
                nil
              t))
      (mentor-details-redisplay))
    (goto-char start-point)))

(defun mentor-file-get-file (dir name)
  "Returns the file with the specified name in the directory
`dir'."
  (let* ((pred (lambda (x) (string= name (mentor-file-name x))))
         (file^ (find-if pred (mentor-file-files dir))))
    (when file^
      file^)))

(defun mentor-file-add-file (dir file)
  "Adds a file to the back of the specified directory."
  (setf (mentor-file-files dir)
        (nconc (mentor-file-files dir) (list file))))

(defun mentor-file-properties (file)
  (let ((face (if (mentor-file-is-dir file)
                  'mentor-directory-face
                nil)))
    (list 'face face
          'type (mentor-file-type file)
          'field (mentor-file-id file)
          'file file
          'show (mentor-file-show file))))

(defun mentor-torrent-detail-screen ()
  "Show information about the specified torrent or the torrent at
point."
  (interactive)
  (let ((tor (mentor-get-item-at-point)))
    (switch-to-buffer "*mentor: torrent details*")
    (setq mentor-sub-mode 'file-details)
    (mentor-mode)
    (setq mentor-set-priority-fun 'mentor-file-set-priority-fun)
    (setq mentor-columns-var  'mentor-file-detail-columns)
    (mentor-reload-header-line)
    (mentor-torrent-details-mode t)
    (setq mentor-selected-torrent tor)
    (mentor-files-update t)
    (mentor-details-redisplay)
    (setq mode-line-buffer-identification (concat "*mentor* "
                                                  (mentor-item-property 'name tor)))
    (if (not (mentor-get-item-type))
        (mentor-next-item 1 t)
      (mentor-beginning-of-item))))

(defun mentor-details-add-files (name-list)
  (let ((root (make-mentor-file :name "/" :type 'dir :id -1 :show t))
        (all-files (make-hash-table :test 'eql))
        (dir-id -1)
        (file-id -1))
    (dolist (names name-list)
      (let* ((file (pop names))
             (len (length names))
             (last-dir root)
             (curr-dir nil))
        (while (> len 0)
          (if (mentor-file-get-file last-dir file)
              (setq last-dir (mentor-file-get-file last-dir file))
            (setq curr-dir (make-mentor-file :name file
                                             :type 'dir :show nil
                                             :id (decf dir-id)))
            (mentor-file-add-file last-dir curr-dir)
            (setq last-dir curr-dir))
          (setq file (pop names))
          (decf len))
        (setq file (make-mentor-file :name file :type 'file
                                     :id (incf file-id)))
        (mentor-file-add-file last-dir file)
        (puthash file-id file all-files)))
    (push (cons 'files all-files) mentor-selected-torrent-info)
    (push (cons 'root root) mentor-selected-torrent-info)))

;; TODO: benchmark if add-files nil really means any performance gain
;;       for large examples
(defun mentor-files-update (&optional add-files)
  (interactive)
  (when add-files
    (setq mentor-selected-torrent-info
          (assq-delete-all 'root mentor-selected-torrent-info))
    (setq mentor-selected-torrent-info
          (assq-delete-all 'files mentor-selected-torrent-info)))
  (let* ((tor mentor-selected-torrent)
         (hash (mentor-item-property 'hash tor))
         (methods mentor-volatile-rpc-f-methods)
         (methods+ (mapcar
                    'mentor-get-some-methods-as-string
                    (if add-files
                        (cons "f.path_components" methods)
                      methods)))
         (methods= (mapcar (lambda (m) (concat m "=")) methods+))
         (value-list (apply 'mentor-rpc-command
                            "f.multicall" hash "" methods=))
         (properties (mapcar 'mentor-rpc-method-to-property methods)))
    (when add-files
      (mentor-details-add-files (mapcar 'car value-list))
      (setq value-list (mapcar 'cdr value-list)))
    (let ((files (cdr (assq 'files mentor-selected-torrent-info)))
          (id -1))
      (dolist (values value-list)
        (let ((_file (gethash (incf id) files)))
          (mapc (lambda (p)
                  (let* ((file-fun (mentor-concat-symbols 'mentor-file- p))
                         (val (if (string-match mentor-methods-to-get-as-string
                                                (symbol-name p))
                                  (string-to-number (pop values))
                                (pop values))))
                    (eval `(setf (,file-fun _file) ,val))))
                properties)))))
  (mentor-details-redisplay))

(defvar mentor-file-detail-columns
  '(((mentor-file-progress) -5 "Cmp")
    ((mentor-file-prio-string) -5 "Pri")
    ((mentor-file-readable-size) 6 "Size")
    (nil 0 "File" 6)))
(defvar mentor-file-detail-width 22)

(defun mentor-insert-file (file infix &optional last)
  (interactive)
  (let ((props (mentor-file-properties file))
        (text (mentor-process-view-columns file mentor-file-detail-columns)))
    (insert (apply 'propertize
                   (concat text " " infix (if last "└── " "├── ")
                           (mentor-file-name file))
                   (cons 'item-start (cons (+ 5 (point) (length text) (length infix))
                                           props)))
            "\n")))

(defun mentor-insert-dir-content (dir &optional infix)
  (interactive)
  (let* ((files (mentor-file-files dir))
         (total (length files))
         (infix (or infix ""))
         (count 1))
    (dolist (file files)
      (if (mentor-file-is-dir file)
          (let* ((show (mentor-file-show file))
                 (symb (if show
                           (if (= count total) "└── " "├── ")
                         "+── "))
                 (margin (concat (make-string mentor-file-detail-width ? )
                                 infix
                                 symb))
                 (text (concat margin (mentor-file-name file)))
                 (infix-next (concat infix
                                      (if (= count total)
                                          "    "
                                        "│   "))))
            (insert (apply 'propertize text
                           'item-start (+ (point) (length margin))
                           (mentor-file-properties file)) "\n")
            (when show
              (mentor-insert-dir-content file infix-next)))
        (mentor-insert-file file infix (= count total)))
      (when (mentor-file-marked file)
        (save-excursion
          (mentor-previous-item t)
          (mentor-mark)))
      (incf count))))

(defun mentor-details-redisplay ()
  (interactive)
  (let* ((inhibit-read-only t)
         (pos (point))
         (root (cdr (assq 'root mentor-selected-torrent-info))))
    (erase-buffer)
    (mentor-reload-header-line)
    (mentor-insert-dir-content root)
    (goto-char pos)))

(defun mentor-details-next-directory ()
  (interactive)
  (when (mentor-file-is-dir (mentor-file-at-point))
    (mentor-next-item))
  (while (not (mentor-file-is-dir (mentor-file-at-point)))
    (mentor-next-item))
  (mentor-beginning-of-item))

(defun mentor-details-previous-directory ()
  (interactive)
  (when (mentor-file-is-dir (mentor-file-at-point))
    (mentor-previous-item))
  (while (not (mentor-file-is-dir (mentor-file-at-point)))
    (mentor-previous-item)
    (mentor-beginning-of-item)))

(defun mentor-mark-dir (file &optional clear-mark no-redisplay)
  (interactive)
  (error "FIXME")
  (when (not (mentor-file-show file))
    (setf (mentor-file-show file) t))
  (dolist (curr-file (mentor-file-files file))
    (let ((curr-file curr-file)
          (new-mark (if clear-mark nil t)))
      (if (mentor-file-is-dir curr-file)
          (mentor-mark-dir curr-file clear-mark t)
        (setf (mentor-file-marked curr-file) new-mark))))
  (when (not no-redisplay)
    (mentor-details-redisplay)))


;;; Utility functions

(defun mentor-limit-num (num min max)
  (cond ((< num min) min)
        ((> num max) max)
        (t num)))

(defun mentor-concat-symbols (&rest symbols)
  (intern (apply 'concat (mapcar 'symbol-name symbols))))

(defun mentor-get-item-type ()
  (interactive)
  (get-text-property (point) 'type))

(defun mentor-prompt-complete (prompt list require-match default)
  (completing-read prompt list nil require-match nil default
                   mentor-last-used-view))

(defun mentor-get-custom-view-name (view-id)
  (cdr (assoc view-id mentor-custom-views)))

(defun mentor-bytes-to-human (bytes)
  (if bytes
      (let* ((bytes (if (stringp bytes) (string-to-number bytes) bytes))
             (kb 1024.0)
             (mb 1048576.0)
             (gb 1073741824.0)
             (tb 1099511627776.0))
        (cond ((< bytes 0) "???") ;; workaround for old xmlrpc-c
              ((< bytes kb) bytes)
              ((< bytes mb) (concat (format "%.1f" (/ bytes kb)) "K"))
              ((< bytes gb) (concat (format "%.1f" (/ bytes mb)) "M"))
              ((< bytes tb) (concat (format "%.1f" (/ bytes gb)) "G"))
              (t "1TB+")))
    ""))

(defun mentor-bytes-to-kilobytes (bytes)
  (if (numberp bytes)
      (if (< bytes 0)
          "???" ;; workaround for old xmlrpc-c
        (number-to-string (/ bytes 1024)))
    ""))

(defun mentor-enforce-length (str maxlen)
  (if (not str)
      (make-string (abs maxlen) ? )
    (format (concat "%" (number-to-string maxlen) "s")
            (substring str 0 (min (length str) (abs maxlen))))))

(provide 'mentor)

;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; indent-tabs-mode: nil
;; End:
;;; mentor.el ends here
