(defgroup neuramind-focus nil
  "Emacs helpers for NeuraMind focus blocks."
  :group 'tools)

(defcustom neuramind-focus-python "python3"
  "Python executable used for the NeuraMind focus helper."
  :type 'string
  :group 'neuramind-focus)

(defcustom neuramind-focus-script
  (expand-file-name "focus_state.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the NeuraMind focus helper script."
  :type 'file
  :group 'neuramind-focus)

(defcustom neuramind-focus-buffer-name "*NeuraMind Focus*"
  "Base buffer name used for NeuraMind focus views."
  :type 'string
  :group 'neuramind-focus)

(defun neuramind-focus--call (&rest args)
  "Call the NeuraMind focus helper with ARGS and return trimmed stdout."
  (with-temp-buffer
    (let ((status (apply #'call-process
                         neuramind-focus-python
                         nil
                         (current-buffer)
                         nil
                         neuramind-focus-script
                         args)))
      (unless (eq status 0)
        (error "NeuraMind focus command failed: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun neuramind-focus--display-buffer (name content)
  "Display CONTENT in a read-only buffer called NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert content)
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buffer)))

(defun neuramind-focus-start (task done-when artifact-goal drift-budget)
  "Start a new NeuraMind focus block."
  (interactive
   (list
    (read-string "Task: ")
    (read-string "Done when: ")
    (read-string "Artifact goal: ")
    (read-number "Drift budget (minutes): " 10)))
  (message "%s"
           (neuramind-focus--call
            "start"
            "--task" task
            "--done-when" done-when
            "--artifact-goal" artifact-goal
            "--drift-budget" (number-to-string drift-budget))))

(defun neuramind-focus-stop (artifact score notes)
  "Stop the current NeuraMind focus block."
  (interactive
   (list
    (read-string "Artifact: ")
    (read-number "Score (0-10): " 8)
    (read-string "Notes: ")))
  (message "%s"
           (neuramind-focus--call
            "stop"
            "--artifact" artifact
            "--score" (number-to-string score)
            "--notes" notes)))

(defun neuramind-focus-status ()
  "Show the current NeuraMind focus block."
  (interactive)
  (let* ((raw (neuramind-focus--call "status"))
         (payload (ignore-errors (json-parse-string raw :object-type 'alist))))
    (if (or (null payload) (= (length payload) 0))
        (message "No active focus block.")
      (message "Active: %s | started %s | artifact %s"
               (alist-get 'task payload)
               (alist-get 'started_at payload)
               (or (alist-get 'artifact_goal payload) "-")))))

(defun neuramind-focus-open-scorecard ()
  "Create and open today's scorecard."
  (interactive)
  (find-file (neuramind-focus--call "scorecard")))

(defun neuramind-focus-list-blocks (&optional limit)
  "Show recent focus blocks in a readable buffer."
  (interactive "P")
  (neuramind-focus--display-buffer
   neuramind-focus-buffer-name
   (neuramind-focus--call "list" "--include-open" "--limit"
                        (number-to-string (prefix-numeric-value (or limit 12))))))

(defun neuramind-focus-productivity (&optional days)
  "Show productivity summary for recent focus blocks."
  (interactive "P")
  (neuramind-focus--display-buffer
   "*NeuraMind Productivity*"
   (neuramind-focus--call "productivity" "--days"
                        (number-to-string (prefix-numeric-value (or days 7))))))

(provide 'neuramind-focus)
