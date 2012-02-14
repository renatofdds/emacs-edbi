;;; edbi.el --- Database independent interface for Emacs

;; Copyright (C) 2011  SAKURAI Masashi

;; Author:  <m.sakurai at kiwanami.net>
;; Keywords: database, epc

;; This program is free software; you can redistribute it and/or modify
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

;; 

;;; Code:


(eval-when-compile (require 'cl))
(require 'epc)
(require 'sql)

;; deferred macro
(defmacro edbi:seq (first-d &rest elements)
  (let* ((pit 'it)
         (vsym (gensym))
         (fs 
          (cond
           ((eq '<- (nth 1 first-d))
            (let ((var (car first-d)) (f (nth 2 first-d)))
              `(deferred:nextc ,f
                 (lambda (,vsym) (setq ,var ,vsym)))))
           (t first-d)))
         (ds (loop for i in elements
                   collect
                   (cond
                    ((eq 'lambda (car i))
                     `(deferred:nextc ,pit ,i))
                    ((eq '<- (nth 1 i))
                     (let ((var (car i)) (f (nth 2 i)))
                     `(deferred:nextc ,pit 
                        (lambda (x) 
                          (deferred:$ ,f
                            (deferred:nextc ,pit
                              (lambda (,vsym) (setq ,var ,vsym))))))))
                    (t
                     `(deferred:nextc ,pit (lambda (x) ,i)))))))
    `(deferred:$ ,fs ,@ds)))


;;; Configurations

(defvar edbi:driver-libpath (file-name-directory (or load-file-name ".")) 
  "directory for the driver program.")

(defvar edbi:driver-info (list "perl" 
                               (expand-file-name 
                                "edbi-bridge.pl" 
                                edbi:driver-libpath))
  "driver program info.")


;;; Low level API

(defun edbi:data-source (uri &optional username auth)
  "Create data source object."
  (list uri username auth))

(defun edbi:data-source-uri (data-source)
  "Return the uri slot of the DATA-SOURCE."
  (car data-source))

(defun edbi:data-source-username (data-source)
  "Return the username slot of the DATA-SOURCE."
  (nth 1 data-source))

(defun edbi:data-source-auth (data-source)
  "Return the auth slot of the DATA-SOURCE."
  (nth 2 data-source))


(defun edbi:start ()
  "Start the EPC process. This function returns an `epc:manager' object."
  (epc:start-epc (car edbi:driver-info) (cdr edbi:driver-info)))

(defun edbi:connect (conn connection-info)
  "Connect to the DB. This function executes peer's API synchronously.
CONNECTION-INFO is a list of (data_source username auth)."
  (prog1
      (epc:call-sync conn 'connect connection-info)
    (setf (epc:manager-title conn) (car connection-info))))

(defun edbi:do-d (conn sql &optional params)
  "Execute SQL and return a number of affected rows."
  (epc:call-deferred conn 'do (cons sql params)))

(defun edbi:select-all-d (conn sql &optional params)
  "Execute the query SQL and returns all result rows."
  (epc:call-deferred conn 'select-all (cons sql params)))

(defun edbi:prepare-d (conn sql)
  "[STH] Prepare the statement for SQL."
  (epc:call-deferred conn 'prepare sql))

(defun edbi:execute-d (conn &optional params)
  "[STH] Execute the statement."
  (epc:call-deferred conn 'execute params))

(defun edbi:fetch-columns-d (conn)
  "[STH] Fetch a list of the column titles."
  (epc:call-deferred conn 'fetch-columns nil))

(defun edbi:fetch-d (conn &optional num)
  "[STH] Fetch a row object. NUM is a number of retrieving rows. If NUM is nil, this function retrieves all rows."
  (epc:call-deferred conn 'fetch num))

(defun edbi:auto-commit-d (conn flag)
  "Set the auto-commit flag. FLAG is 'true' or 'false' string."
  (epc:call-deferred conn 'auto-commit flag))

(defun edbi:commit-d (conn)
  "Commit transaction."
  (epc:call-deferred conn 'commit nil))

(defun edbi:rollback-d (conn)
  "Rollback transaction."
  (epc:call-deferred conn 'rollback nil))

(defun edbi:disconnect-d (conn)
  "Close the DB connection."
  (epc:stop-epc conn))

(defun edbi:status-info-d (conn)
  "Return a list of `err' code, `errstr' and `state'."
  (epc:call-deferred conn 'status nil))


(defun edbi:table-info-d (conn catalog schema table type)
  "Return a table info as (COLUMN-LIST ROW-LIST)."
  (epc:call-deferred conn 'table-info (list catalog schema table type)))

(defun edbi:column-info-d (conn catalog schema table column)
  "Return a column info as (COLUMN-LIST ROW-LIST)."
  (epc:call-deferred conn 'column-info (list catalog schema table column)))

(defun edbi:primary-key-info-d (conn catalog schema table)
  "Return a primary key info as (COLUMN-LIST ROW-LIST)."
  (epc:call-deferred conn 'primary-key-info (list catalog schema table)))

(defun edbi:foreign-key-info-d (conn pk-catalog pk-schema pk-table 
                                   fk-catalog fk-schema fk-table)
  "Return a foreign key info as (COLUMN-LIST ROW-LIST)."
  (epc:call-deferred conn 'foreign-key-info
                     (list pk-catalog pk-schema pk-table 
                           fk-catalog fk-schema fk-table)))

(defun edbi:column-selector (columns name)
  "[internal] Return a column selector function."
  (lexical-let (num)
    (loop for c in columns
          for i from 0
          if (equal c name)
          return (progn 
                   (setq num i)
                   (lambda (xs) (nth num xs))))))


;;; High level API



;;; User Interface

(defun edbi:dialog-data-source-buffer (data-source on-ok-func 
                                                   &optional password-show error-msg)
  "[internal] Create and return the editing buffer for the given DATA-SOURCE."
  (let ((buf (get-buffer-create "*edbi-dialog-data-source*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer))
      (kill-all-local-variables)
      (remove-overlays)
      (erase-buffer)
      (widget-insert (format "Data Source: [driver: %s]\n\n" edbi:driver-info))
      (when error-msg
        (widget-insert
         (let ((text (substring-no-properties error-msg)))
           (put-text-property 0 (length text) 'face 'font-lock-warning-face text)
           text))
        (widget-insert "\n\n"))
      (lexical-let 
          ((data-source data-source) (on-ok-func on-ok-func) (error-msg error-msg)
           fdata-source fusername fauth cbshow fields)
        ;; create dialog fields
        (setq fdata-source
              (widget-create
               'editable-field
               :size 30 :format "  Data Source: %v \n"
               :value (or (edbi:data-source-uri data-source) ""))
              fusername
              (widget-create
               'editable-field
               :size 20 :format "   User Name : %v \n"
               :value (or (edbi:data-source-username data-source) ""))
              fauth 
              (widget-create
               'editable-field
               :size 20 :format "        Auth : %v \n"
               :secret (and (not password-show) ?*)
               :value (or (edbi:data-source-auth data-source) "")))
        (widget-insert "    (show auth ")
        (setq cbshow
              (widget-create 'checkbox  :value password-show))
        (widget-insert " ) ")
        (setq fields
              (list 'data-source fdata-source
                    'username fusername 'auth fauth 
                    'password-show cbshow))

        ;; OK / Cancel
        (widget-insert "\n")
        (widget-create 
         'push-button
         :notify (lambda (&rest ignore)
                   (edbi:dialog-data-source-commit data-source fields on-ok-func))
         "Ok")
        (widget-insert " ")
        (widget-create
         'push-button
         :notify (lambda (&rest ignore)
                   (edbi:dialog-data-source-kill-buffer))
         "Cancel")
        (widget-insert "\n")

        ;; add event actions
        (widget-put cbshow
                    :notify
                    (lambda (&rest ignore)
                      (let ((current-ds
                             (edbi:data-source
                              (widget-value fdata-source)
                              (widget-value fusername)
                              (widget-value fauth)))
                            (password-show (widget-value cbshow)))
                        (edbi:dialog-replace-buffer-window
                         (current-buffer)
                         current-ds on-ok-func password-show error-msg)
                        (widget-forward 3))))

        ;; setup widgets
        (use-local-map widget-keymap)
        (widget-setup)
        (goto-char (point-min))
        (widget-forward 1)))
    buf))

(defun edbi:dialog-data-source-cbshow (data-source fields on-ok-func)
  "[internal] Click action for the checkbox of [show auth]."
  (let ((current-ds
         (edbi:data-source
          (widget-value (plist-get fields 'data-source))
          (widget-value (plist-get fields 'username))
          (widget-value (plist-get fields 'auth))))
        (password-show (widget-value cbshow)))
    (edbi:dialog-replace-buffer-window
     (current-buffer)
     current-ds on-ok-func password-show error-msg)
    (widget-forward 3)))

(defun edbi:dialog-data-source-commit (data-source fields on-ok-func)
  "[internal] Click action for the [OK] button."
  (let ((uri-value (widget-value (plist-get fields 'data-source))))
    (cond
     ((or (null uri-value)
          (string-equal "" uri-value))
      (edbi:dialog-replace-buffer-window
       (current-buffer)
       data-source on-ok-func
       (widget-value (plist-get fields 'password-show))
       "Should not be empty!"))
     (t
      (setq data-source
            (edbi:data-source
             uri-value
             (widget-value (plist-get fields 'username))
             (widget-value (plist-get fields 'auth))))
      (let ((msg (funcall on-ok-func data-source)))
        (if msg 
            (edbi:dialog-replace-buffer-window
             (current-buffer)
             data-source on-ok-func
             (widget-value (plist-get fields 'password-show))
             (format "Connection Error : %s" msg))
          (edbi:dialog-data-source-kill-buffer)))))))

(defun edbi:dialog-data-source-kill-buffer ()
  "[internal] Kill dialog buffer."
  (interactive)
  (let ((cbuf (current-buffer))
        (win-num (length (window-list))))
    (when (and (not (one-window-p))
               (> win-num edbi:dialog-before-win-num))
      (delete-window))
    (kill-buffer cbuf)))

(defvar edbi:dialog-before-win-num 0  "[internal] ")

(defun edbi:dialog-replace-buffer-window (prev-buf data-source on-ok-func 
                                                   &optional password-show error-msg)
  "[internal] Kill the previous dialog buffer and create new dialog buffer."
  (let ((win (get-buffer-window prev-buf)) new-buf)
    (edbi:dialog-data-source-kill-buffer)
    (setq new-buf
          (edbi:dialog-data-source-buffer
           data-source on-ok-func password-show error-msg))
    (cond
     ((or (null win) (not (window-live-p win)))
      (pop-to-buffer new-buf))
     (t
      (set-window-buffer win new-buf)
      (set-buffer new-buf)))
    new-buf))

(defun edbi:dialog-data-source-open (on-ok-func)
  "[internal] Display a dialog for data source information."
  (setq edbi:dialog-before-win-num (length (window-list)))
  (pop-to-buffer
   (edbi:dialog-data-source-buffer
    (edbi:data-source nil) on-ok-func)))

(defface edbi:face-title
  '((((class color) (background light))
     :foreground "DarkGrey" :weight bold :height 1.2 :inherit variable-pitch)
    (((class color) (background dark))
     :foreground "darkgoldenrod3" :weight bold :height 1.2 :inherit variable-pitch)
    (t :height 1.2 :weight bold :inherit variable-pitch))
  "Face for title" :group 'edbi)

(defface edbi:face-header
  '((((class color) (background light))
     :foreground "Slategray4" :background "Gray90" :weight bold)
    (((class color) (background dark))
     :foreground "maroon2" :weight bold))
  "Face for headers" :group 'edbi)


;; database viewer

(defun edbi:open-db-viewer ()
  "Open Database viewer buffer."
  (interactive)
  (let ((connection-func
         (lambda (ds)
           (let (conn msg)
             (setq msg
                   (condition-case err
                       (progn
                         (setq conn (edbi:start))
                         (edbi:connect conn data-source)
                         nil)
                     (error (setq (format "%s" msg)))))
             (cond
              ((null msg)
               (deferred:call 'edbi:dbview-open data-source conn) nil)
              (t msg))))))
    (edbi:dialog-data-source-open connection-func)))

(defvar edbi:dbview-buffer-name "*edbi-dbviewer*" "[internal] Database buffer name.")

(defvar edbi:dbview-keymap
  (epc:add-keymap
   ctbl:table-mode-map
   '(
     ("g"   . edbi:dbview-update-command)
     ("SPC" . edbi:dbview-show-table-definition-command)
     ("c"   . edbi:dbview-query-editor-command)
     ("C-m" . edbi:dbview-show-table-data-command)
     ("q"   . edbi:dbview-quit-command)
     )) "Keymap for the DB Viewer buffer.")

(defun edbi:dbview-header (data-source &optional items)
  "[internal] "
  (concat
   (propertize (format "DB: %s\n" (edbi:data-source-uri data-source))
               'face 'edbi:face-title)
   (if items
       (propertize (format "[%s items]\n" (length items))
                   'face 'edbi:face-header))))

(defun edbi:dbview-open (data-source conn)
  "[internal] "
  (with-current-buffer (get-buffer-create edbi:dbview-buffer-name)
    (let (buffer-read-only)
      (erase-buffer)
      (set (make-local-variable 'edbi:data-source) data-source)
      (set (make-local-variable 'edbi:connection) conn)
      (insert (edbi:dbview-header data-source)
              "\n[connecting...]")))
  (unless (equal edbi:dbview-buffer-name (buffer-name))
    (pop-to-buffer edbi:dbview-buffer-name))
  (lexical-let ((data-source data-source) (conn conn) results)
    (edbi:seq
     (results <- (edbi:table-info-d conn nil nil nil nil))
     (lambda (x) 
       (edbi:dbview-create-buffer data-source conn results)))))

(defun edbi:dbview-create-buffer (data-source conn results)
  "[internal] "
  (let* ((buf (get-buffer-create edbi:dbview-buffer-name))
         (hrow (and results (car results)))
         (rows (and results (cadr results)))
         (data (loop with catalog-f = (edbi:column-selector hrow "TABLE_CAT")
                     with schema-f  = (edbi:column-selector hrow "TABLE_SCHEM")
                     with table-f   = (edbi:column-selector hrow "TABLE_NAME")
                     with type-f    = (edbi:column-selector hrow "TABLE_TYPE")
                     with remarks-f = (edbi:column-selector hrow "REMARKS")
                     for row in rows
                     for catalog = (funcall catalog-f row)
                     for schema  = (funcall schema-f row)
                     for type    = (funcall type-f row)
                     for table   = (funcall table-f row)
                     for remarks = (funcall remarks-f row)
                     unless (string-match "\\(INDEX\\|SYSTEM\\)" type)
                     collect
                     (list (concat catalog schema) table type remarks
                           (list catalog schema table)))) table-cp)
    (with-current-buffer buf
      (let (buffer-read-only)
        (erase-buffer)
        (insert (edbi:dbview-header data-source data))
        (setq table-cp 
              (ctbl:create-table-component-region
               :model
               (make-ctbl:model
                :column-model
                (list (make-ctbl:cmodel :title "Schema"    :align 'left)
                      (make-ctbl:cmodel :title "Table Name" :align 'left)
                      (make-ctbl:cmodel :title "Type"  :align 'center)
                      (make-ctbl:cmodel :title "Remarks"  :align 'left))
                :data data
                :sort-state '(1 2))
               :keymap edbi:dbview-keymap))
        (goto-char (point-min))
        (ctbl:cp-set-selected-cell table-cp '(0 . 0)))
      (setq buffer-read-only t)
      buf)))

(eval-when-compile ; introduce anaphoric variable `cp' and `table'.
  (defmacro edbi:dbview-with-cp (&rest body)
    `(let ((cp (ctbl:cp-get-component)))
       (when cp
         (let ((table (car (last (ctbl:cp-get-selected-data-row cp)))))
           ,@body)))))

(defun edbi:dbview-quit-command ()
  (interactive)
  (let ((conn edbi:connection))
    (edbi:dbview-with-cp
     (when (and conn (y-or-n-p "Quit and disconnect DB ? "))
       (epc:stop-epc conn)
       (kill-buffer (current-buffer))))))

(defun edbi:dbview-update-command ()
  (interactive)
  (let ((conn edbi:connection) (ds edbi:data-source))
    (when conn
      (edbi:dbview-open ds conn))))

(defun edbi:dbview-show-table-definition-command ()
  (interactive)
  (let ((conn edbi:connection) (ds edbi:data-source))
    (when conn
      (edbi:dbview-with-cp
       (destructuring-bind (catalog schema table) table
         (edbi:dbview-table-definition-open
          ds conn catalog schema table))))))

(defun edbi:dbview-query-editor-command ()
  "ARGS"
  (interactive)
  (let ((conn edbi:connection) (ds edbi:data-source))
    (when conn
      (edbi:dbview-with-cp
       (edbi:dbview-query-editor-open ds conn)))))

(defvar edbi:dbview-show-table-data-default-limit 50
  "edbi:dbview-show-table-data-default-limit.")

(defun edbi:dbview-show-table-data-command ()
  (interactive)
  (let ((conn edbi:connection) (ds edbi:data-source))
    (when conn
      (edbi:dbview-with-cp
       (destructuring-bind (catalog schema table-name) table
         (edbi:dbview-query-editor-open 
          ds conn 
          (if edbi:dbview-show-table-data-default-limit
              (format "SELECT * FROM %s LIMIT 50" 
                      table-name edbi:dbview-show-table-data-default-limit)
            (format "SELECT * FROM %s" table-name)) t))))))


;; query editor and viewer

(defvar edbi:sql-mode-map 
  (epc:define-keymap
   '(
     ("C-c C-c" . edbi:dbview-query-editor-execute-command)
     )) "Keymap for the `edbi:sql-mode'.")

(defvar edbi:sql-mode-hook nil  "edbi:sql-mode-hook.")

(defun edbi:sql-mode ()
  "Major mode for SQL. This function is copied from sql.el and modified."
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'edbi:sql-mode)
  (setq mode-name "EDBI SQL")
  (use-local-map edbi:sql-mode-map)
  (set-syntax-table sql-mode-syntax-table)
  (make-local-variable 'font-lock-defaults)
  (make-local-variable 'sql-mode-font-lock-keywords)
  (make-local-variable 'comment-start)
  (setq comment-start "--")
  (make-local-variable 'paragraph-separate)
  (make-local-variable 'paragraph-start)
  (setq paragraph-separate "[\f]*$"	paragraph-start "[\n\f]")
  ;; Abbrevs
  (setq local-abbrev-table sql-mode-abbrev-table)
  (setq abbrev-all-caps 1)
  ;; Run hook
  (if (fboundp 'run-mode-hooks)
      (run-mode-hooks 'edbi:sql-mode-hook)
    (run-hooks 'edbi:sql-mode-hook))
  (sql-product-font-lock nil t))


(defvar edbi:dbview-uid 0 "[internal] ")

(defun edbi:dbview-uid ()
  "[internal] "
  (incf edbi:dbview-uid))

(defun edbi:dbview-query-editor-create-buffer ()
  "[internal] "
  (let* ((uid (edbi:dbview-uid))
         (buf-name (format "*edbi:query-editor %s *" uid))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (edbi:sql-mode)
      (set (make-local-variable 'edbi:buffer-id) uid))
    buf))

(defun edbi:dbview-query-editor-open (data-source conn &optional init-sql executep)
  "[internal] "
  (let ((buf (edbi:dbview-query-editor-create-buffer)))
    (with-current-buffer buf
      (set (make-local-variable 'edbi:data-source) data-source)
      (set (make-local-variable 'edbi:connection) conn)
      (set (make-local-variable 'edbi:result-buffer) nil)
      (when init-sql
        (insert init-sql)))
    (switch-to-buffer buf)
    (when executep
      (with-current-buffer buf
        (edbi:dbview-query-editor-execute-command)))))

(defun edbi:dbview-query-result-get-buffer (buf)
  "[internal] "
  (let* ((uid (buffer-local-value 'edbi:buffer-id buf))
         (rbuf-name (format "*edbi:query-result %s" uid))
         (rbuf (get-buffer rbuf-name)))
    (unless rbuf
      (setq rbuf (get-buffer-create rbuf-name))
      (with-current-buffer rbuf
        (set (make-local-variable 'edbi:query-buffer) buf)))
    rbuf))

(defun edbi:dbview-query-editor-execute-command ()
  "Execute SQL and show result buffer."
  (interactive)
  (when edbi:connection
    (let ((sql (buffer-substring-no-properties (point-min) (point-max)))
          (result-buf edbi:result-buffer))
      (unless result-buf
        (setq result-buf (edbi:dbview-query-result-get-buffer (current-buffer))))
      (edbi:dbview-query-execute edbi:connection sql result-buf))))

(defun edbi:dbview-query-execute (conn sql result-buf)
  "[internal] "
  (lexical-let ((conn conn) (sql sql) (result-buf result-buf))
    (deferred:$
      (edbi:seq
       (edbi:prepare-d conn sql)
       (edbi:execute-d conn nil)
       (lambda (exec-result)
         (cond
          ((equal "0E0" exec-result)
           (lexical-let (rows header)
             (edbi:seq
              (rows <- (edbi:fetch-d conn))
              (header <- (edbi:fetch-columns-d conn))
              (lambda (x)
                (edbi:dbview-query-result-open result-buf header rows)))))
          (t (edbi:dbview-query-result-text result-buf exec-result)))))
      (deferred:error it
        (lambda (err) (message "ERROR : %S" err))))))

(defun edbi:dbview-query-result-text (buf execute-result)
  "[internal] "
  (with-current-buffer buf
    (let (buffer-read-only)
      (erase-buffer)
      (insert (format "OK. %s rows are affected.\n" execute-result))))
  (pop-to-buffer buf))

(defvar edbi:dbview-query-result-keymap
  (epc:define-keymap
   '(
     ("q"   . edbi:dbview-query-result-quit-command)
     )) "Keymap for the query result viewer buffer.")

(defun edbi:dbview-query-result-open (buf header rows)
  "[internal] "
  (let (table-cp)
    (setq table-cp
          (ctbl:create-table-component-buffer
           :buffer buf
           :model
           (make-ctbl:model
            :column-model
            (loop for i in header
                  collect (make-ctbl:cmodel :title (format "%s" i) 
                                            :align 'left :min-width 5))
            :data rows
            :sort-state nil)
           :custom-map edbi:dbview-query-result-keymap))
    (ctbl:cp-set-selected-cell table-cp '(0 . 0))
    (with-current-buffer buf
      (set (make-local-variable 'edbi:before-win-num) (length (window-list))))
    (pop-to-buffer buf)))

(defun edbi:dbview-query-result-quit-command ()
  "Quit the query result buffer."
  (interactive)
  (let ((cbuf (current-buffer))
        (win-num (length (window-list))))
    (when (and (not (one-window-p))
               (> win-num edbi:before-win-num))
      (delete-window))
    (kill-buffer cbuf)))


;; table definition viewer

(defvar edbi:dbview-table-buffer-name "*edbi-dbviewer-table*" "[internal] Table buffer name.")

(defvar edbi:dbview-table-keymap
  (epc:add-keymap
   ctbl:table-mode-map
   '(
     ("g"   . edbi:dbview-table-definition-update-command)
     ("q"   . edbi:dbview-table-definition-quit-command)
     ("c"   . edbi:dbview-table-definition-query-editor-command)
     ("V"   . edbi:dbview-table-definition-show-data-command)
     )) "Keymap for the DB Table Viewer buffer.")

(defun edbi:dbview-table-definition-header (data-source table-name &optional items)
  "[internal] "
  (concat
   (propertize (format "Table: %s\n" table-name) 'face 'edbi:face-title)
   (format "DB: %s\n" (edbi:data-source-uri data-source))
   (if items
     (propertize (format "[%s items]\n" (length items)) 'face 'edbi:face-header))))

(defun edbi:dbview-table-definition-open (data-source conn catalog schema table)
  "[internal] "
  (with-current-buffer
      (get-buffer-create edbi:dbview-table-buffer-name)
    (let (buffer-read-only)
      (erase-buffer)
      (set (make-local-variable 'edbi:before-win-num) (length (window-list)))
      (set (make-local-variable 'edbi:table-definition)
           (list data-source conn catalog schema table))
      (insert (edbi:dbview-table-definition-header data-source table)
              "[connecting...]\n")))
  (unless (equal (buffer-name) edbi:dbview-table-buffer-name)
    (pop-to-buffer edbi:dbview-table-buffer-name))
  (lexical-let ((data-source data-source) (conn conn) 
                (catalog catalog) (schema schema) (table table)
                column-info pkey-info index-info)
    (edbi:seq
     (column-info <- (edbi:column-info-d conn catalog schema table nil))
     (pkey-info   <- (edbi:primary-key-info-d conn catalog schema table))
     (index-info  <- (edbi:table-info-d conn catalog schema table "INDEX"))
     (lambda (x) 
       (edbi:dbview-table-definition-create-buffer 
        data-source conn table
        column-info pkey-info index-info)))))

(defun edbi:dbview-table-definition-get-pkey-info (pkey-info column-name)
  "[internal] "
  (loop with pkey-hrow = (car pkey-info)
        with pkey-rows = (cadr pkey-info)
        with pkname-f = (edbi:column-selector pkey-hrow "PK_NAME")
        with keyseq-f = (edbi:column-selector pkey-hrow "KEY_SEQ")
        with cname-f = (edbi:column-selector pkey-hrow "COLUMN_NAME")
        for row in pkey-rows
        for cname = (funcall cname-f row)
        if (equal column-name cname)
        return (format "%s %s" 
                       (funcall pkname-f row)
                       (funcall keyseq-f row))
        finally return ""))

(defun edbi:dbview-table-definition-create-buffer (data-source conn table-name column-info pkey-info index-info)
  "[internal] "
  (let* ((buf (get-buffer-create edbi:dbview-table-buffer-name))
         (hrow (and column-info (car column-info)))
         (rows (and column-info (cadr column-info)))
         (data
          (loop with column-name-f = (edbi:column-selector hrow "COLUMN_NAME")
                with type-name-f   = (edbi:column-selector hrow "TYPE_NAME")
                with column-size-f = (edbi:column-selector hrow "COLUMN_SIZE")
                with nullable-f    = (edbi:column-selector hrow "NULLABLE")
                with remarks-f     = (edbi:column-selector hrow "REMARKS")
                for row in rows
                for column-name = (funcall column-name-f row)
                for type-name   = (funcall type-name-f row)
                for column-size = (funcall column-size-f row)
                for nullable    = (funcall nullable-f row)
                for remarks     = (funcall remarks-f row)
                collect
                (list column-name type-name 
                      (or column-size "")
                      (edbi:dbview-table-definition-get-pkey-info pkey-info column-name)
                      (if (equal nullable 0) "NOT NULL" "") remarks
                      row))) table-cp)
    (with-current-buffer buf
      (let (buffer-read-only)
        (erase-buffer)
        ;; header
        (insert (edbi:dbview-table-definition-header data-source table-name data))
        ;; table
        (setq table-cp
              (ctbl:create-table-component-region
               :model
               (make-ctbl:model
                :column-model
                (list (make-ctbl:cmodel :title "Column Name" :align 'left)
                      (make-ctbl:cmodel :title "Type"    :align 'left)
                      (make-ctbl:cmodel :title "Size"    :align 'right)
                      (make-ctbl:cmodel :title "PKey"    :align 'left)
                      (make-ctbl:cmodel :title "Null"    :align 'left)
                      (make-ctbl:cmodel :title "Remarks" :align 'left))
                :data data
                :sort-state nil)
               :keymap edbi:dbview-table-keymap))
        ;; indexes
        (let ((index-rows (and index-info (cadr index-info))))
          (when index-rows
            (insert "\n"
                    (propertize (format "[Index: %s]\n" (length index-rows))
                                'face 'edbi:face-header))
            (loop for row in index-rows ; maybe index column (sqlite)
                  do (insert (format "- %s\n" (nth 5 row))))))

        (goto-char (point-min))
        (ctbl:cp-set-selected-cell table-cp '(0 . 0)))
      (setq buffer-read-only t)
      (current-buffer))))

(defun edbi:dbview-table-definition-show-data-command ()
  ""
  (interactive)
  (let ((args edbi:table-definition))
    (when args
      (destructuring-bind (data-source conn catalog schema table-name) args
        (edbi:dbview-query-editor-open 
         data-source conn 
         (if edbi:dbview-show-table-data-default-limit
             (format "SELECT * FROM %s LIMIT 50" 
                     table-name edbi:dbview-show-table-data-default-limit)
           (format "SELECT * FROM %s" table-name)) t)))))

(defun edbi:dbview-table-definition-query-editor-command ()
  (interactive)
  (let ((args edbi:table-definition))
    (when args
      (destructuring-bind (data-source conn catalog schema table-name) args
        (edbi:dbview-query-editor-open data-source conn)))))

(defun edbi:dbview-table-definition-quit-command ()
  (interactive)
  (let ((cbuf (current-buffer))
        (win-num (length (window-list))))
    (when (and (not (one-window-p))
               (> win-num edbi:before-win-num))
      (delete-window))
    (kill-buffer cbuf)))

(defun edbi:dbview-table-definition-update-command ()
  (interactive)
  (let ((args edbi:table-definition))
    (when args
      (apply 'edbi:dbview-table-definition-open args))))

(provide 'edbi)
;;; edbi.el ends here