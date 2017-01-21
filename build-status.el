;;; build-status.el --- Mode line build status indicator

;; Author: Skye Shaw <skye.shaw@gmail.com>
;; Version: 0.0.1
;; Keywords: mode-line, ci, circleci
;; Package-Requires: ((cl-lib "0.5"))
;; URL: http://github.com/sshaw/build-status

;; This file is NOT part of GNU Emacs.

;;; License:

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

;; Minor mode that shows a buffer's build status in the mode line.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

(defvar build-status-check-interval 300
  "Interval at which to check the build status.  Given in seconds, defaults to 300.")

(defvar build-status-color-alist
  '(("passed"
     ((background-color . "green")))
    ("failed"
     ((background-color . "red")))
    ("running"
     ((background-color . "yellow"))))
  "Alist of statuses and the face properties to use when displayed.
Each element looks like (STATUS PROPERTIES).  STATUS is a status
string (one of: passed, failed, running, or unknown) and PROPERTIES
is a list of text property cons.")

(defvar build-status-circle-ci-token nil
  "CircleCI API token.
The API token can also be sit via: `git config --add build-status.api-token`.")

(defvar build-status-circle-ci-status-mapping-alist
  '(("success"   . "passed")
    ("scheduled" . "queued"))
  "Alist of CircleCI status to build-status statuses. build-status statuses are:
passed, failed, running.")

(defvar build-status-travis-ci-status-mapping-alist
  '(("started" . "running")
    ("created" . "queued"))  ;; need to actually handle this state
  "Alist of TravsCI status to build-status statuses.  build-status statuses are:
passed, failed, running.")

(defvar build-status--project-status-alist '()
  "Alist of project roots and their build status.")

(defvar build-status--timer nil)
(defvar build-status--remote-regex
  "\\(github\\|bitbucket\\).com\\(?:/\\|:[0-9]*/?\\)\\([^/]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?$")

(defvar build-status--mode-line-map (make-sparse-keymap))
(define-key build-status--mode-line-map [mode-line mouse-1] 'build-status-open-circle-ci)

(defun build-status--git(&rest args)
  (car (apply 'process-lines `("git" ,@(when args args)))))

(defun build-status--remote (path branch)
  (let ((remote (build-status--git "-C" path "config" "--get" (format "branch.%s.remote" branch))))
    (build-status--git "-C" path "config" "--get" (format "remote.%s.url" remote))))

(defun build-status--branch (path)
  (build-status--git "-C" path "symbolic-ref" "--short" "HEAD"))

(defun build-status--project-root (path looking-for)
  (when path
    (setq path (file-name-as-directory path))
    (if (file-exists-p (concat path looking-for))
        path
      ;; Make sure we're not at the root directory
      (when (not (string= path (directory-file-name path)))
        (build-status--project-root (file-name-directory (directory-file-name path))
                                    looking-for)))))

(defun build-status--any-open-buffers (root buffers)
  (stringp (cl-find root
                    buffers
                    :test (lambda (start-with buffer)
                            (eq t
                                ;; prefer compare-string as it's not strict with bounds like substring
                                (compare-strings start-with 0 (length start-with)
                                                 (or buffer "") 0 (length start-with)))))))

(defun build-status--project (filename)
  "Return a list containing information on `FILENAME''s CI project.
The list contains:
CI service, api token, project root directory, VCS service, username, project, branch.

If `FILENAME' is not part of a CI project return nil."
  (let ((root (build-status--circle-ci-project-root filename))
        branch
        remote)

    (when root
      (setq branch (build-status--branch root))
      (setq remote (build-status--remote root branch))
      (when (string-match build-status--remote-regex remote)
        (list 'circleci
              (or (ignore-errors (build-status--git "-C" root "config" "--get" "build-status.api-token"))
                  build-status-circle-ci-token)
              root
              (match-string 1 remote)
              (match-string 2 remote)
              (match-string 3 remote)
              branch)))))

(defun build-status--circle-ci-project-root (path)
  (build-status--project-root path "circle.yml"))

(defun build-status--travis-ci-project-root (path)
  (build-status--project-root path ".travis.yml"))

(defun build-status-open-circle-ci ()
  "Open the CircleCI web page for the project."
  (interactive)
  (let ((project (build-status--project (buffer-file-name)))
        root
        url)

    (when project
      ;; "bb" here is just a guess for Bitbucket :)
      (setq root (if (string= "github" (nth 3 project)) "gh" "bb"))
      (setq url  (format "https://circleci.com/%s/%s/%s/tree/%s"
                         root
                         (nth 4 project)
                         (nth 5 project)
                         (nth 6 project)))
      (browse-url url))))

(defun build-status--circle-ci-status (project)
  (let* ((url (apply 'format "https://circleci.com/api/v1.1/project/%s/%s/%s/tree/%s?limit=1&circle-token=%s"
		     `(,@(cdddr project) ,(nth 1 project))))
	 (url-request-method "GET")
	 (url-request-extra-headers '(("Content-Type" . "application/json")))
         json
         status)
    (with-current-buffer (url-retrieve-synchronously url t t)
      ;;(message "%s\n%s" url (buffer-substring-no-properties 1 (point-max)))
      (goto-char (point-min))
      (when (and (search-forward-regexp "HTTP/1\\.[01] \\([0-9]\\{3\\}\\)")
                 (not (string= (match-string 1) "200")))
        (error "CircleCI request failed with HTTP status %s" (match-string 1)))

      (search-forward-regexp "\n\n")
      (setq json (json-read))
      ;; If the build is running there's no outcome so we check status
      (setq status (or (cdr (assoc 'outcome (elt json 0)))
                       (cdr (assoc 'status  (elt json 0)))))
      (or (cdr (assoc status build-status-circle-ci-status-mapping-alist))
          status))))

(defun build-status--update-status ()
  (let ((buffers (mapcar (lambda (b) (buffer-file-name b)) (buffer-list)))
        config
        project)

    (dolist (root (mapcar 'car build-status--project-status-alist))
      (setq config (assoc root build-status--project-status-alist))
      (setq project (build-status--project root))
      (if (and project (build-status--any-open-buffers root buffers))
          (condition-case e
              (setcdr config (list (build-status--circle-ci-status project)))
            (error (message "Failed to update status for %s: %s" root (cadr e))))
        (setq build-status--project-status-alist
              (delete config build-status--project-status-alist)))))

  (force-mode-line-update t)
  (setq build-status--timer
        (run-at-time build-status-check-interval nil 'build-status--update-status)))

(defun build-status--propertize (lighter status)
  (let ((color (cadr (assoc status build-status-color-alist))))
    (propertize (if color (concat " " lighter " ") lighter)
                'help-echo (concat "Build status: " status)
                'local-map build-status--mode-line-map
                'mouse-face 'mode-line-highlight
                'face color)))

(defcustom build-status--mode-line-string
  '(:eval
    (let* ((root (build-status--circle-ci-project-root (buffer-file-name)))
           (status (cadr (assoc root build-status--project-status-alist))))
      (if (null status)
          ""
        (concat " "
                (cond
                 ((string= status "passed")
                  (build-status--propertize "P" status))
                 ((string= status "running")
                  (build-status--propertize "R" status))
                 ((string= status "failed")
                  (build-status--propertize "F" status))
                 (t
                  (build-status--propertize "?" (or status "unknown"))))))))
  "Build status mode line string."
  :type 'sexp
  :risky t)

(define-minor-mode build-status-mode
  "Monitor the build status of the buffer's project."
  :global t
  (when build-status--timer
    (cancel-timer build-status--timer))

  (let ((project (build-status--project (buffer-file-name)))
        root)

    (when (null project)
      (setq build-status-mode nil)
      (error "Not a CircleCI project"))

    (setq root (nth 2 project))
    (if (not build-status-mode)
        (progn
          (setq build-status--project-status-alist
                (delete (assoc root build-status--project-status-alist)
                        build-status--project-status-alist))
          ;; Only remove from the mode line if there are no more projects
          (when (null build-status--project-status-alist)
            (delq 'build-status--mode-line-string global-mode-string)))

      (when (null (nth 1 project))
        (setq build-status-mode nil)
        (error "No CircleCI api token has been configured"))

      (add-to-list 'global-mode-string 'build-status--mode-line-string t)
      (add-to-list 'build-status--project-status-alist (list root nil))

      (build-status--update-status))))

(provide 'build-status-mode)
;;; build-status.el ends here
