#!/usr/bin/env guile
!#

;; Copyright (c) 2022 Nikolay Puzanov <punzik@gmail.com>
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.

;; -*- geiser-scheme-implementation: guile -*-

(import
 ;; (scheme base)                ; R7RS base (not needed for Guile)
 (srfi srfi-1)                   ; Lists
 (srfi srfi-9)                   ; Records
 (srfi srfi-11)                  ; let-values
 (srfi srfi-13)                  ; String library
 (srfi srfi-28)                  ; Simple format
 (srfi srfi-39))                 ; Parameters

(use-modules
 (ice-9 regex)
 (ice-9 popen)
 (ice-9 textual-ports)
 (ice-9 threads)
 (ice-9 getopt-long))

(define APP_VERSION "0.0.1")

(define MAKEFILE_NAME_REGEXP ".*\\.utest$")
(define TIMEOUT_MODULE_NAME  "utest_timeout")
(define DUMP_MODULE_NAME     "utest_dump")
(define WORK_DIR_PREFIX      "")

;;; Globals
(define utest/force-dump    (make-parameter #f))
(define utest/restart-dump  (make-parameter #f))
(define utest/keep-output   (make-parameter #f))
(define utest/verbose       (make-parameter #f))
(define utest/nocolor       (make-parameter #f))
(define utest/base-path     (make-parameter ""))
(define utest/work-path     (make-parameter ""))

(define-record-type <log-type>
  (log-type log-prefix color out-prefix verbose)
  log-type?
  (log-prefix lt-log-prefix)
  (color      lt-color)
  (out-prefix lt-out-prefix)
  (verbose    lt-verbose))

(define LOG_PREFIX_INFO "INFO#")
(define LOG_PREFIX_WARN "WARN#")
(define LOG_PREFIX_FAIL "FAIL#")

(define log-types
  `((info      ,(log-type LOG_PREFIX_INFO 15  "   | " #t))
    (warning   ,(log-type LOG_PREFIX_WARN 226 "   + " #t))
    (error     ,(log-type LOG_PREFIX_FAIL 196 "   + " #t))
    (test-head ,(log-type "TSTH#"         14  ""      #t))
    (test-info ,(log-type "TSTI#"         6   ""      #t))
    (test-succ ,(log-type "TSTS#"         47  ""      #t))
    (test-fail ,(log-type "TSTF#"         196 ""      #t))))

(define log-type-default
  (log-type "" 244 "   | " #f))

;;; Like assoc but with functional predicate
(define (assf f l)
  (find (lambda (x) (f (car x))) l))

;;; Get log type by id (level)
(define (log-type-by-id id)
  (let ((t (assq id log-types)))
    (if t (cadr t) log-type-default)))

;;; Get log type with log-prefix matched to prefix of str
(define (log-type-by-prefix str)
  (let ((t (assf (lambda (x) (string-prefix? x str))
                 (map (lambda (x) (let ((t (cadr x)))
                               (list (lt-log-prefix t) t)))
                      log-types))))
    (if t (cadr t) log-type-default)))

;;; Useful print functions
(define (printf . rest) (display (apply format rest)))
(define (println . rest) (for-each (lambda (x) (display x) (newline)) rest))

;;; Return log line as string
(define (utest/slog a . args)
  (if (string? a)
      (apply format a args)
      (string-append
       (lt-log-prefix (log-type-by-id a))
       (apply format args))))

;;; Display log line
;;; Split line by newline character and display
;;; each piece as seperate line.
(define (utest/log a . args)
  (let* ((pre (if (string? a) "" (lt-log-prefix (log-type-by-id a))))
         (fmt (if (string? a) (cons a args) args))
         (strs
          (map (lambda (x) (string-append pre x))
               (string-split
                (apply format fmt)
                #\newline))))
    (for-each println strs) #t))

;;;
;;; Colorize text
;;;
(define* (color text fg #:optional (bg 'default))
  (format "~a~a~a~a[0m"
          ;; Foreground
          (if (number? fg)
              (format "~a[38;5;~am" #\esc fg)
              (format "~a[~am" #\esc (case fg
                                       ((black)   "30")
                                       ((red)     "31")
                                       ((green)   "32")
                                       ((yellow)  "33")
                                       ((blue)    "34")
                                       ((magenta) "35")
                                       ((cyan)    "36")
                                       ((white)   "37")
                                       ((default) "39"))))
          ;; Background
          (if (number? bg)
              (format "~a[48;5;~am" #\esc bg)
              (format "~a[~am" #\esc (case bg
                                       ((black)   "40")
                                       ((red)     "41")
                                       ((green)   "42")
                                       ((yellow)  "43")
                                       ((blue)    "44")
                                       ((magenta) "45")
                                       ((cyan)    "46")
                                       ((white)   "47")
                                       ((default) "49"))))
          text #\esc))

;;;
;;; Print log
;;;
(define (convert-log-item item colorize)
  (let* ((t (log-type-by-prefix item))
         (pre (lt-out-prefix t))
         (str (substring item (string-length (lt-log-prefix t)))))
    (string-append
     pre
     (if colorize
         (color str (lt-color t))
         str))))

(define* (print-log log-strings
                    #:key
                    (verbose #f)
                    (colorize #f))
  (for-each
   (lambda (str)
     (let ((t (log-type-by-prefix str)))
       (when (or verbose (lt-verbose t))
         (println (convert-log-item str colorize)))))
   log-strings))

;;;
;;; Catch exception and continue with default value
;;;
(define-syntax guard
  (syntax-rules ()
    ((_ default code...)
     (with-exception-handler (lambda (e) default)
       (lambda () code...)
       #:unwind? #t))))

;;;
;;; Check path existence
;;; If path not exists throw exception
;;;
(define (check-path path)
  (if (not (file-exists? path))
      (raise-exception (format "Path ~a is not exists" path))
      (let ((type (stat:type (stat path))))
        (if (or (not (access? path R_OK))
                (and (eq? type 'directory)
                     (not (access? path X_OK))))
            (raise-exception (format "Path ~a is not readable" path))
            #t))))

;;;
;;; Convert path to absolute path
;;;
(define* (path->absolute path #:optional (base ""))
  (let ((path
         (if (or (string-null? base)
                 (absolute-file-name? path))
             path
             (string-append base "/" path))))
    (check-path path)
    (canonicalize-path path)))

;;;
;;; Create file with simulation timeout watchdog
;;;
(define (create-timeout-module path modname timeout)
  (define (* . fmt) (println (apply format fmt)))
  (let ((filename (format "~a/~a.v" path modname)))
    (with-output-to-file filename
      ;; #:exists 'replace
      (lambda ()
        (* "// Automatically generated file")
        (* "`timescale 1ps/1ps")
        (* "module ~a();" modname)
        (* "  initial begin")
        (if (list? timeout)
            (* "    #(~a~a);"
               (car timeout)
               (if (null? (cdr timeout))
                   ""
                   (symbol->string (cadr timeout))))
            (* "    #~a;" timeout))
        (* "    $display(\"~aTimeout at %0t\", $time);"
           (lt-log-prefix (log-type-by-id 'error)))
        (* "    $finish;")
        (* "  end")
        (* "endmodule")))
    (path->absolute filename)))

;;;
;;; Create dump module
;;;
(define (create-dump-module path modname top dump-type)
  (define (* . fmt) (println (apply format fmt)))
  (let ((filename (format "~a/~a.v" path modname)))
    (with-output-to-file filename
      ;; #:exists 'replace
      (lambda ()
        (* "// Automatically generated file")
        (* "`timescale 1ps/1ps")
        (* "module ~a();" modname)
        (* "  initial begin")
        (* "    $dumpfile(\"~a/~a.~a\");" path top dump-type)
        (* "    $dumpvars(0, ~a);" top)
        (* "  end")
        (* "endmodule")))
    (path->absolute filename)))

;;;
;;; Return directory list
;;;
(define (list-dir path)
  (if (file-exists? path)
      (let ((dir (opendir path)))
        (let loop ((ls '()))
          (let ((item (readdir dir)))
            (if (eof-object? item)
                (begin
                  (closedir dir)
                  ls)
                (if (or (string=? item ".")
                        (string=? item ".."))
                    (loop ls)
                    (loop (cons (string-append path "/" item) ls)))))))
      '()))

;;;
;;; Recursive delete directory
;;;
(define (delete-recursive path)
  (let ((path (path->absolute path)))
    (if (eq? 'directory (stat:type (stat path)))
        (begin
          (for-each delete-recursive (list-dir path))
          (rmdir path))
        (delete-file path))))

;;;
;;; Recursive find path items for which the function f returns true
;;; (fn fullpath type) : (-> (string symbol) boolean)
;;; Returns empty list if files not found
;;;
(define* (find-paths-rec fn base #:optional (follow-symlink #f))
  (let ((ls (list-dir base)))
    (let ((files.dirs
           (fold (lambda (name f.d)
                   ;; There is a risk that some paths may have disappeared during recursive search.
                   ;; To avoid an error, we can catch the exception from the stat function

                   ;; (let ((t (guard #f (stat:type (stat name)))))
                   ;;   (if t
                   ;;       (let* ((files (car f.d))
                   ;;              (dirs  (cdr f.d))
                   ;;              (f (if (fn name t) (cons name files) files)))
                   ;;         (if (or (eq? t 'directory)
                   ;;                 (and follow-symlink
                   ;;                      (eq? t symlink)))
                   ;;             (cons f (cons name dirs))
                   ;;             (cons f dirs)))
                   ;;       f.d))

                   (let* ((files (car f.d))
                          (dirs  (cdr f.d))
                          (t (stat:type (stat name)))
                          (f (if (fn name t) (cons name files) files)))
                     (if (or (eq? t 'directory)
                             (and follow-symlink
                                  (eq? t symlink)))
                         (cons f (cons name dirs))
                         (cons f dirs))))
                 '(()) ls)))
      (let ((files (car files.dirs))
            (dirs (cdr files.dirs)))
        (fold (lambda (dir files)
                (append files (find-paths-rec fn dir follow-symlink)))
              files dirs)))))

;;;
;;; Recursive find files with name matched a regular expression
;;; (find-files-rec-regexp rx base [follow-symlink #f]) -> (listof path?)
;;;   rx   : string?
;;;   base : string?
;;;   follow-symlink : boolean?
;;;
;;; rx - regulat expression
;;; base - base directory for files search
;;;
(define* (find-files-rec-regexp rx base #:optional (follow-symlink #f))
  (if (eq? 'regular (stat:type (stat base)))
      (if (string-match rx (basename base)) (list base) '())
      (find-paths-rec
       (lambda (f t)
         (and (eq? t 'regular)
              (string-match rx (basename f))))
       base follow-symlink)))

;;;
;;; Recursive find files in testbench base directory
;;;
(define* (utest/find-files-rec rx #:key (base "") (follow-symlink #f))
  (find-files-rec-regexp
   rx
   (if (string-null? base)
       (utest/base-path)
       (format "~a/~a" (utest/base-path) base))
   follow-symlink))

;;;
;;; Find files in testbench base directory
(define* (utest/find-files rx #:key (base "") (follow-symlink #f))
  (let* ((base (path->absolute
                (if (string-null? base)
                    (utest/base-path)
                    (format "~a/~a" (utest/base-path) base))))
         (ls (list-dir base)))
    (filter (lambda (f)
              (and (not (string=? f "."))
                   (not (string=? f ".."))
                   (string-match rx f)))
            ls)))

;;;
;;; Prepare argument list
;;;   #f -> '()
;;;   Value -> '(Value)
;;;   '(...) -> '(...)
;;;
(define (arg-to-list arg)
  (cond ((not arg)'())
        ((list? arg) arg)
        (else (list arg))))

;;;
;;; Flatten list
;;;
(define (flatten x)
  (cond ((null? x) '())
        ((pair? x) (append (flatten (car x)) (flatten (cdr x))))
        (else (list x))))

;;;
;;; Trim list
;;;
(define (list-trim-left l pred)
  (if (or (null? l) (not (pred (car l))))
      l
      (list-trim-left (cdr l) pred)))

(define (list-trim-right l pred)
  (reverse (list-trim-left (reverse l) pred)))

(define (list-trim l pred)
  (list-trim-right
   (list-trim-left l pred)
   pred))

;;;
;;; Execute system command and capture stdout and stderr to string list
;;;
(define (system-to-string-list cmd)
  (let* ((cmd (string-append cmd " 2>&1;"))
         (p (open-input-pipe cmd))
         (out (get-string-all p)))
    (values
     (close-pipe p)
     (list-trim (string-split out #\newline) string-null?))))

;;;
;;; Compile code with Icarus Verilog
;;;
(define* (iverilog-compile sources
                           #:key
                           (iverilog-executable "iverilog")
                           (modpaths '())           ; -y
                           (modtypes '(".v" ".sv")) ; -Y
                           (includes '())           ; -I
                           (top #f)                 ; -s
                           (output #f)              ; -o
                           (lang "2012")            ; -g2012
                           (features '())           ; -g
                           (vpipaths '())           ; -L
                           (vpimods '())            ; -m
                           (libs '())               ; -l
                           (netlist #f)             ; -N
                           (separate #f)            ; -u
                           (warnings "all")         ; -W
                           (defines '())            ; -D=X
                           (parameters '())         ; -P=X
                           (other '()))

  (define (string-or-num-param x)
    (if (number? x)
        (format "~a" x)
        (format "'\"~a\"'" x)))

  (let ((opts
         (cons
          iverilog-executable
          (append
           (if lang (list (format "-g~a" lang)) '())
           (if output (list "-o" output) '())
           (if separate '("-u") '())
           (if netlist (list (format "-N~a" netlist)) '())
           (flatten (map (lambda (x) (list "-s" x)) (arg-to-list top)))
           (map (lambda (x) (format "-W~a" x)) (arg-to-list warnings))
           (map (lambda (x) (format "-y~a" x)) (arg-to-list modpaths))
           (map (lambda (x) (format "-Y~a" x)) (arg-to-list modtypes))
           (map (lambda (x) (format "-I~a" x)) (arg-to-list includes))
           (map (lambda (x) (format "-g~a" x)) (arg-to-list features))
           (map (lambda (x) (format "-L~a" x)) (arg-to-list vpipaths))
           (map (lambda (x) (format "-m~a" x)) (arg-to-list vpimods))
           (map (lambda (x) (format "-l~a" x)) (arg-to-list libs))
           (map (lambda (x)
                  (format "-P~a=~a"
                          (if (or (not top) (list? top))
                              (car x)
                              (format "~a.~a" top (car x)))
                          (string-or-num-param (cadr x))))
                parameters)
           (map (lambda (x)
                  (if (list? x)
                      (format "-D~a=~a" (car x) (string-or-num-param (cadr x)))
                      (format "-D~a" x)))
                defines)
           other
           (arg-to-list sources)))))

    (let ((cmdline (fold (lambda (x s) (string-append s x " ")) "" opts)))
      (let-values (((status output)
                    (system-to-string-list cmdline)))
        (values (= status 0) cmdline output)))))

;;;
;;; Run simulation of executable compiled with Icarus Verilog
;;;
(define* (iverilog-run vvp-binary
                       #:key
                       (vvp-executable "vvp")
                       (vpipaths '())           ; -M
                       (vpimods '())            ; -m
                       (dumpformat 'fst)
                       (plusargs '()))
  (let ((opts
         (cons
          vvp-executable
          (append
           (map (lambda (x) (format "-M~a" x)) (arg-to-list vpipaths))
           (map (lambda (x) (format "-m~a" x)) (arg-to-list vpimods))
           (list "-N" vvp-binary)   ; $finish on CTRL-C
           (case dumpformat
             ((vcd) '("-vcd"))
             ((fst) '("-fst"))
             ((lxt) '("-lxt"))
             ((lxt2) '("-lxt2"))
             ((none) '("-none"))
             (else '()))
           (map (lambda (x) (format "+~a" x)) plusargs)))))

    (let ((cmdline (fold (lambda (x s) (string-append s x " ")) "" opts)))
      (let-values (((status output)
                    (system-to-string-list cmdline)))
        (let ((status
               ;; Fix vvp issue (https://github.com/steveicarus/iverilog/issues/737)
               (if (find (lambda (x) (string-prefix? "VCD Error: " x)) output) -1 status)))
          (values (= status 0) cmdline output))))))

;;;
;;; Check log for errors or warnings
;;;
(define (check-log log)
  (let ((sim-fail-prefix (lt-log-prefix (log-type-by-id 'error)))
        (sim-warn-prefix (lt-log-prefix (log-type-by-id 'warning))))
    (cond
     ((find (lambda (x) (string-prefix? sim-fail-prefix x)) log) #f)
     ((find (lambda (x) (string-prefix? sim-warn-prefix x)) log) 'warning)
     (else #t))))

;;;
;;; Return list of UTEST_* defines
;;;
(define (utest-verilog-defines)
  (append
   `((UTEST_BASE_DIR ,(format "'\"~a\"'" (utest/base-path)))
     (UTEST_WORK_DIR ,(format "'\"~a\"'" (utest/work-path))))

   (fold (lambda (x l)
           (if (car x)
               (append l (cdr x))
               l))
         '()
         `((,(utest/verbose)      UTEST_VERBOSE)
           (,(utest/force-dump)   UTEST_FORCE_DUMP)
           (,(utest/keep-output)  UTEST_KEEP_OUTPUT)
           (,(utest/restart-dump) UTEST_RESTART_DUMP)))))

;;;
;;; Run compile and simulation with Icarus Verilog
;;;
(define* (utest/run-simulation-iverilog sources
                                        top
                                        #:key
                                        (iverilog-executable "iverilog")
                                        (vvp-executable "vvp")
                                        (modpaths '())
                                        (modtypes '(".v" ".sv"))
                                        (includes '())
                                        (lang "2012")
                                        (parameters '())
                                        (defines '())
                                        (features '())
                                        (separate #f)
                                        (plusargs '())
                                        (vpimods '())
                                        (vpipaths '())
                                        (warnings "all")
                                        (dumpformat 'fst)
                                        (timeout '(1 s)))

  ;; Get parameters
  (let ((force-dump (utest/force-dump))
        (base-path (utest/base-path))
        (work-path (utest/work-path)))

    ;; Create helper modules - timeout watchdog and waveform dumper
    (let ((timeout-module (create-timeout-module work-path TIMEOUT_MODULE_NAME timeout))
          (dump-module (create-dump-module work-path DUMP_MODULE_NAME top dumpformat)))

      ;; Convert relative paths to absolute
      (let ((sources (append (map (lambda (x) (path->absolute x base-path))
                                  (arg-to-list sources))
                             (list timeout-module dump-module)))
            (defines (append defines (utest-verilog-defines)))
            (includes (append (map (lambda (x) (path->absolute x base-path)) (arg-to-list includes))
                              (list base-path)))

            (modpaths (map (lambda (x) (path->absolute x base-path)) (arg-to-list modpaths)))
            (vpipaths (map (lambda (x) (path->absolute x base-path)) (arg-to-list vpipaths)))
            (execfile (format "~a/~a.vvp" work-path top)))

        (let ((succ
               ;; Start compilation
               (let-values
                   (((succ cmdl outp)
                     (iverilog-compile sources
                                       #:iverilog-executable iverilog-executable #:modpaths modpaths
                                       #:modtypes '(".v" ".sv") #:includes includes
                                       #:top top #:other `("-s" ,TIMEOUT_MODULE_NAME "-s" ,DUMP_MODULE_NAME)
                                       #:output execfile #:lang lang #:features features #:vpipaths vpipaths
                                       #:vpimods vpimods #:separate separate #:warnings warnings #:defines defines
                                       #:parameters parameters)))

                 ;; Print iverilog command line and output
                 (printf "$ ~a\n" cmdl)
                 (for-each println outp)

                 ;; Run simulation. On error the simulation will retry
                 ;; with dump enabled, if needed
                 (if succ
                     (let retry ((dump force-dump))
                       (let-values
                           (((succ cmdl outp)
                             (iverilog-run execfile
                                           #:vvp-executable vvp-executable #:vpipaths vpipaths
                                           #:vpimods vpimods #:dumpformat (if dump dumpformat 'none)
                                           #:plusargs plusargs)))
                         (let ((succ (if succ (check-log outp) succ)))
                           (if (or succ dump (not (utest/restart-dump)))
                               (begin
                                 ;; Print vvp command line and output
                                 (printf "$ ~a\n" cmdl)
                                 (for-each println outp)
                                 succ)
                               (retry #t)))))
                     succ))))
          succ)))))

;;;
;;; Return all test procs from make files
;;; Return list of pairs (base-dir . test-proc)
;;;
(define (collect-test-procs files)
  (fold
   (lambda (f procs)
     (let* ((f (path->absolute f))
            (base (dirname f)))
       (append
        procs
        (filter
         car
         (map (lambda (proc) (list proc base (basename f)))
              (let ((procs
                     (parameterize ((utest/base-path base)
                                    (utest/work-path #f))
                       (load f))))
                (if procs
                    (if (list? procs) procs
                        (if (procedure? procs)
                            (list procs)
                            '(#f)))
                    '(#f))))))))
   '() files))

;;;
;;; Call test proc. Collect output to list of string
;;;
(define (call-test test work)
  (let* ((pass #f)
         (proc  (car test))
         (base  (cadr test))
         (name  (proc 'name))
         (name  (format "~a~a/~a"
                        (let* ((pwd (string-append (path->absolute (getcwd)) "/"))
                               (base-loc
                                (if (string-prefix? pwd base)
                                    (substring base (string-length pwd))
                                    base)))
                          (if (string-null? base-loc)
                              ""
                              (string-append base-loc "/")))
                        (caddr test)
                        (if name name "-")))
         (descr (proc 'description))
         (log
          (string-split
           (with-output-to-string
             (lambda ()
               (utest/log 'test-head "TEST ~a" name)
               (when descr (utest/log 'test-info "~a" descr))
               (utest/log "Base: ~a" base)
               (utest/log "Work: ~a" work)
               (set! pass
                     (with-exception-handler (lambda (e)
                                               (display "EXCEPTION: ")
                                               (display e) #f)
                       (lambda ()
                         (parameterize ((utest/base-path base)
                                        (utest/work-path work))
                           (proc)))
                       #:unwind? #t))))
           #\newline)))

    ;; Check log
    (let ((log (append log
                       (list (if pass
                                 (utest/slog 'test-succ "PASS")
                                 (utest/slog 'test-fail "FAIL (~a)" (basename work)))))))
      (values pass log))))

;;;
;;; Create temporary working directory, call test,
;;; print log to stdout and save verbose log to a file.
;;;
;;; test : (list test-proc base-path makefile-base-name)
;;; returns: (values pass output)
;;;
(define (execute-test test)
  (let ((proc (car test))
        (base (cadr test))
        (makefile-name (caddr test)))
    (let* ((name (proc 'name))
           (name (if name name "noname"))
           (work (mkdtemp (format "~a/~a~a-~a-~a-XXXXXX"
                                  base WORK_DIR_PREFIX
                                  makefile-name
                                  (string-map (lambda (c) (if (char-whitespace? c) #\_ c))
                                              (string-downcase name))
                                  (current-time)))))
      ;; Execute test
      (let* ((p #f)
             (o (with-output-to-string
                  (lambda ()
                    (let-values (((pass log)
                                  (call-test test work)))
                      (set! p pass)

                      ;; Print log
                      (print-log log
                                 #:colorize (not (utest/nocolor))
                                 #:verbose (or (utest/verbose)
                                               (not (eq? pass #t))))

                      ;; Save log
                      (with-output-to-file (format "~a/log.txt" work)
                        (lambda () (print-log log #:colorize #f #:verbose #t)))

                      ;; Delete work dir if test pass and no need to keep directory
                      (if (and (eq? pass #t)
                               (not (utest/force-dump))
                               (not (utest/keep-output)))
                          (begin
                            (when (utest/verbose)
                              (printf "Delete work dir ~a\n" work))
                            (delete-recursive work))
                          (printf "See output at ~a\n" work)))))))
        (values p o)))))

;;;
;;; Execute tests in series (in one thread)
;;; tests : list-of (test-proc base-path makefile-base-name)
;;;
(define (execute-tests tests)
  (let ((test-count (length tests))
        (pass-count
         (fold (lambda (test cnt)
                 (let-values (((pass out) (execute-test test)))
                   (println out)
                   (+ cnt (if pass 1 0))))
               0 tests)))
    (printf "PASSED ~a/~a\n\n" pass-count test-count)))

;;;
;;; Execute tests in parallel
;;; tests : list-of (test-proc base-path makefile-base-name)
;;;
(define (execute-tests-parallel tests max-threads-count)
  (let ((test-count (length tests)))
    (let loop ((tests tests)
               (threads '())
               (pass-count 0))

      (if (and (null? tests)
               (null? threads))
          ;; Done
          (printf "PASSED ~a/~a\n\n" pass-count test-count)

          ;; Not all tests complete
          (let ((threads-prev threads))
            ;; Run new thread if thread pool is not full
            (let-values
                (((tests threads)
                  (if (and (< (length threads) max-threads-count)
                           (not (null? tests)))
                      (let* ((test (car tests))
                             (thd
                              (call-with-new-thread
                               (lambda ()
                                 (execute-test test)))))
                        (values (cdr tests) (cons thd threads)))
                      (values tests threads))))

              ;; Get exited threads
              (let* ((trest.passc
                      (fold
                       (lambda (thd t.p)
                         (let ((trest (car t.p))
                               (passc  (cdr t.p)))
                           (if (thread-exited? thd)
                               (let-values (((pass out) (join-thread thd)))
                                 (println out)
                                 (cons trest (+ passc (if pass 1 0))))
                               (cons (cons thd trest) passc))))
                       (cons '() pass-count) threads))

                     (threads    (car trest.passc))
                     (pass-count (cdr trest.passc)))

                ;; Sleep when no new threads and no exited threads
                (when (= (length threads-prev)
                         (length threads))
                  (usleep 10000)
                  (yield))

                ;; Loop
                (loop tests threads pass-count))))))))

;;;
;;; Test item macro
;;;
(define-syntax utest/tb
  (syntax-rules ()
    ((_ (n d ...) body ...)
     (lambda id
       (cond
        ((null? id) (begin body ...))
        ((eq? (car id) 'name) n)
        ((eq? (car id) 'description)
         ((lambda rest
            (if (null? rest)
                #f
                (string-append
                 (car rest)
                 (apply string-append
                        (map (lambda (x) (string-append "\n" x))
                             (cdr rest))))))
          d ...))
        (else #f))))

    ((_ () body ...)
     (utest/tb (#f) body ...))))

;;;
;;; Delete working folders
;;;
(define (delete-work-dirs base force)
  (let ((work-dirs
         (if force
             (find-paths-rec
              (lambda (p t)
                (and (eq? t 'directory)
                     (string-match
                      (format "^~a.*-[0-9]{10}-.{6}$" WORK_DIR_PREFIX)
                      (basename p))))
              base)
             (fold
              (lambda (makefile work-dirs)
                (append
                 work-dirs
                 (find-paths-rec
                  (lambda (p t)
                    (and (eq? t 'directory)
                         (string-match
                          (format "^~a~a.*-[0-9]{10}-.{6}$" WORK_DIR_PREFIX (basename makefile))
                          (basename p))))
                  (dirname makefile))))
              '() (find-files-rec-regexp MAKEFILE_NAME_REGEXP base)))))
    (if (null? work-dirs)
        (printf "Working folders not found\n")
        (for-each
         (lambda (dir)
           (printf "Delete \"~a\"\n" dir)
           (delete-recursive dir))
         work-dirs))))

;;;
;;; Print log level verilog defines
;;;
(define (print-verilog-defines)
  (define (* . fmt) (apply printf fmt) (newline))
  (* "`ifndef UTEST_VERILOG_DEFINES")
  (* " `define UTEST_VERILOG_DEFINES")
  (* "")
  (* "// Log level string prefixes for use with $display function.")
  (* "// Example usage: $display(\"%sError message\", `LOG_ERR);")
  (* " `define LOG_INFO \"~a\"" LOG_PREFIX_INFO)
  (* " `define LOG_WARN \"~a\"" LOG_PREFIX_WARN)
  (* " `define LOG_ERR  \"~a\"" LOG_PREFIX_FAIL)
  (* "")
  (* "// Dirty hacked redefine of $display function. Must be used with two parentheses.")
  (* "// Example usage: `log_info((\"Information message\"));")
  (* " `define log_info(msg)  begin $display({`LOG_INFO, $sformatf msg}); end")
  (* " `define log_warn(msg)  begin $display({`LOG_WARN, $sformatf msg}); end")
  (* " `define log_error(msg) begin $display({`LOG_ERR, $sformatf msg}); end")
  (* "`endif"))

;;;
;;; Print help
;;;
(define (print-help app-name)
  (define (* . fmt) (apply printf fmt) (newline))
  (* "Usage: ~a [OPTION]... [FILE|PATH]" app-name)
  (* "Run testbenches with recursive search in the PATH, or in the current folder")
  (* "if PATH is not specified. If argument is a file, testbench is launched from FILE.")
  (* "")
  (* "Options:")
  (* "  -k, --keep           Do not delete work directory if test is pass.")
  (* "  -d, --dump           Force dump waveforms.")
  (* "  -r, --norestart      Do not restart testbench with waveform dump enabled if")
  (* "                       test failed (true by default)")
  (* "  -n, --nocolor        Do not use color for print log")
  (* "  -j, --jobs NUM       Use NUM threads for running testbenches. If <=0")
  (* "                       use as many threads as there are processors in the system.")
  (* "  -f, --defines        Print useful Verilog defines")
  (* "  -c, --clean          Delete work folders that have a corresponding makefile.")
  (* "      --force-clean    Delete all work folders regardless of the presence of a makefile.")
  (* "  -v, --verbose        Verbose output")
  (* "  -V, --version        Print version")
  (* "  -h, --help           Print this message and exit")
  (* "")
  (* "Source code and issue tracker: <https://github.com/punzik/utest>"))

;;;
;;; Print app version, legals and copyright
;;;
(define (print-version)
  (define (* . fmt) (apply printf fmt) (newline))
  (* "utest ~a" APP_VERSION))

;;;
;;; Main
;;;
(let ((args (command-line)))
  (let* ((optspec `((keep (single-char #\k))
                    (dump (single-char #\d) (value #f))
                    (norestart (single-char #\r) (value #f))
                    (nocolor (single-char #\n) (value #f))
                    (verbose (single-char #\v) (value #f))
                    (jobs (single-char #\j) (value #t) (predicate ,string->number))
                    (help (single-char #\h) (value #f))
                    (version (single-char #\V) (value #f))
                    (clean (single-char #\c) (value #f))
                    (force-clean (value #f))
                    (defines (single-char #\f) (value #f))))

         (options (getopt-long args optspec))
         (jobs    (string->number (option-ref options 'jobs "0")))
         (jobs    (if (zero? jobs) (current-processor-count) jobs))
         (rest    (option-ref options '() '()))
         (path    (path->absolute (if (null? rest) (getcwd) (car rest)))))

    (cond
     ((option-ref options 'help #f)        (print-help (car args)))
     ((option-ref options 'version #f)     (print-version))
     ((option-ref options 'defines #f)     (print-verilog-defines))
     ((option-ref options 'clean #f)       (delete-work-dirs path #f))
     ((option-ref options 'force-clean #f) (delete-work-dirs path #t))

     (else
      (utest/keep-output  (option-ref options 'keep #f))
      (utest/force-dump   (option-ref options 'dump #f))
      (utest/restart-dump (not (option-ref options 'norestart #f)))
      (utest/nocolor      (option-ref options 'nocolor #f))
      (utest/verbose      (option-ref options 'verbose #f))

      (let ((makefiles
             (if (eq? 'regular (stat:type (stat path)))
                 (list path)
                 (find-files-rec-regexp MAKEFILE_NAME_REGEXP path))))

        (if (<= jobs 1)
            (execute-tests (collect-test-procs makefiles))
            (execute-tests-parallel (collect-test-procs makefiles) jobs)))))))
