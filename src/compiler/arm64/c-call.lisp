;;;; VOPs and other machine-specific support routines for call-out to C

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(defconstant +number-stack-alignment-mask+ (1- (* n-word-bytes 2)))

(defconstant +max-register-args+ 8)

(defun my-make-wired-tn (prim-type-name sc-name offset)
  (make-wired-tn (primitive-type-or-lose prim-type-name)
                 (sc-number-or-lose sc-name)
                 offset))

(defstruct arg-state
  (num-register-args 0)
  (fp-registers 0)
  (stack-frame-size 0))

(defstruct (result-state (:copier nil))
  (num-results 0))

(defun result-reg-offset (slot)
  (ecase slot
    (0 nl0-offset)
    (1 nl1-offset)))

(defun register-args-offset (index)
  (elt '#.(list nl0-offset nl1-offset nl2-offset nl3-offset nl4-offset nl5-offset nl6-offset
                      nl7-offset)
       index))

(defun int-arg (state prim-type reg-sc stack-sc)
  (let ((reg-args (arg-state-num-register-args state)))
    (cond ((< reg-args +max-register-args+)
           (setf (arg-state-num-register-args state) (1+ reg-args))
           (my-make-wired-tn prim-type reg-sc (register-args-offset reg-args)))
          (t
           (let ((frame-size (arg-state-stack-frame-size state)))
             (setf (arg-state-stack-frame-size state) (1+ frame-size))
             (my-make-wired-tn prim-type stack-sc frame-size))))))

(define-alien-type-method (integer :arg-tn) (type state)
  (if (alien-integer-type-signed type)
      (int-arg state 'signed-byte-64 'signed-reg 'signed-stack)
      (int-arg state 'unsigned-byte-64 'unsigned-reg 'unsigned-stack)))

(define-alien-type-method (system-area-pointer :arg-tn) (type state)
  (declare (ignore type))
  (int-arg state 'system-area-pointer 'sap-reg 'sap-stack))

(define-alien-type-method (single-float :arg-tn) (type state)
  (declare (ignore type))
  (let ((register (arg-state-fp-registers state)))
    (cond ((> register 15)
           (let ((frame-size (arg-state-stack-frame-size state)))
             (setf (arg-state-stack-frame-size state) (1+ frame-size))
             (my-make-wired-tn 'single-float 'single-stack frame-size)))
          (t
           (incf (arg-state-fp-registers state))
           (my-make-wired-tn 'single-float 'single-reg register)))))

(define-alien-type-method (double-float :arg-tn) (type state)
  (declare (ignore type))
  (let ((register (setf (arg-state-fp-registers state)
                        (logandc2 (+ (arg-state-fp-registers state) 1) 1))))
    (cond ((> register 15)
           (let ((frame-size
                   ;; align
                   (setf (arg-state-stack-frame-size state)
                         (logandc2 (+ (arg-state-stack-frame-size state) 1) 1))))
             (setf (arg-state-stack-frame-size state) (+ frame-size 2))
             (my-make-wired-tn 'double-float 'double-stack frame-size)))
          (t
           (incf (arg-state-fp-registers state) 2)
           (my-make-wired-tn 'double-float 'double-reg register)))))

(define-alien-type-method (integer :result-tn) (type state)
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (multiple-value-bind (ptype reg-sc)
        (if (alien-integer-type-signed type)
            (values 'signed-byte-64 'signed-reg)
            (values 'unsigned-byte-64 'unsigned-reg))
      (my-make-wired-tn ptype reg-sc
                        (result-reg-offset num-results)))))

(define-alien-type-method (system-area-pointer :result-tn) (type state)
  (declare (ignore type state))
  (my-make-wired-tn 'system-area-pointer 'sap-reg (result-reg-offset 0)))


(define-alien-type-method (single-float :result-tn) (type state)
  (declare (ignore type state))
  (my-make-wired-tn 'single-float 'single-reg 0))

(define-alien-type-method (double-float :result-tn) (type state)
  (declare (ignore type state))
  (my-make-wired-tn 'double-float 'double-reg 0))

(define-alien-type-method (values :result-tn) (type state)
  (let ((values (alien-values-type-values type)))
    (when (> (length values) 2)
      (error "Too many result values from c-call."))
    (mapcar (lambda (type)
              (invoke-alien-type-method :result-tn type state))
            values)))

(defun make-call-out-tns (type)
  (let ((arg-state (make-arg-state)))
    (collect ((arg-tns))
      (dolist (arg-type (alien-fun-type-arg-types type))
        (arg-tns (invoke-alien-type-method :arg-tn arg-type arg-state)))
      (values (make-normal-tn *fixnum-primitive-type*)
              (* (arg-state-stack-frame-size arg-state) n-word-bytes)
              (arg-tns)
              (invoke-alien-type-method :result-tn
                                        (alien-fun-type-result-type type)
                                        (make-result-state))))))

(define-vop (foreign-symbol-sap)
  (:translate foreign-symbol-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (let ((fixup-label (gen-label)))
      (inst load-from-label res fixup-label)
      (assemble (*elsewhere*)
        (emit-label fixup-label)
        (inst dword (make-fixup foreign-symbol :foreign))))))

#!+linkage-table
(define-vop (foreign-symbol-dataref-sap)
  (:translate foreign-symbol-dataref-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (let ((fixup-label (gen-label)))
      (inst load-from-label res)
      (inst ldr res (@ res))
      (assemble (*elsewhere*)
        (emit-label fixup-label)
        (inst dword (make-fixup foreign-symbol :foreign-dataref))))))

(define-vop (call-out)
  (:args (function :scs (sap-reg sap-stack))
         (args :more t))
  (:results (results :more t))
  (:ignore args results)
  (:save-p t)
  (:temporary (:sc any-reg :offset r8-offset
               :from (:argument 0) :to (:result 0)) cfunc)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:temporary (:sc any-reg :offset r9-offset) temp)
  (:vop-var vop)
  (:generator 0
    (let ((call-into-c-fixup (gen-label))
          (cur-nfp (current-nfp-tn vop)))
      (assemble (*elsewhere*)
        (emit-label call-into-c-fixup)
        (inst dword (make-fixup "call_into_c" :foreign)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (inst load-from-label temp call-into-c-fixup)
      (sc-case function
        (sap-reg (move cfunc function))
        (sap-stack
         (load-stack-offset cfunc cur-nfp function)))
      (inst blr temp)
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))

(define-vop (alloc-number-stack-space)
  (:info amount)
  (:result-types system-area-pointer)
  (:results (result :scs (sap-reg any-reg)))
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount +number-stack-alignment-mask+)
                             +number-stack-alignment-mask+)))
        (inst sub nsp-tn nsp-tn (add-sub-immediate delta))
        (inst mov-sp result nsp-tn)))))

(define-vop (dealloc-number-stack-space)
  (:info amount)
  (:policy :fast-safe)
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount +number-stack-alignment-mask+)
                             +number-stack-alignment-mask+)))
        (composite-immediate-instruction add nsp-tn nsp-tn delta)))))

;;; long-long support
(deftransform %alien-funcall ((function type &rest args) * * :node node)
  (aver (sb!c::constant-lvar-p type))
  (let* ((type (sb!c::lvar-value type))
         (env (sb!c::node-lexenv node))
         (arg-types (alien-fun-type-arg-types type))
         (result-type (alien-fun-type-result-type type)))
    (aver (= (length arg-types) (length args)))
    (if (or (some (lambda (type)
                    (and (alien-integer-type-p type)
                         (> (sb!alien::alien-integer-type-bits type) 64)))
                  arg-types)
            (and (alien-integer-type-p result-type)
                 (> (sb!alien::alien-integer-type-bits result-type) 64)))
        (collect ((new-args) (lambda-vars) (new-arg-types))
                 (loop with i = 0
                       for type in arg-types
                       for arg = (gensym)
                       do
                       (lambda-vars arg)
                       (cond ((and (alien-integer-type-p type)
                                   (> (sb!alien::alien-integer-type-bits type) 64))
                              (when (oddp i)
                                ;; long-long is only passed in pairs of r0-r1 and r2-r3,
                                ;; and the stack is double-word aligned
                                (incf i)
                                (new-args 0)
                                (new-arg-types (parse-alien-type '(signed 8) env)))
                              (incf i 2)
                              (new-args `(logand ,arg #xffffffff))
                              (new-args `(ash ,arg -64))
                              (new-arg-types (parse-alien-type '(unsigned 64) env))
                              (if (alien-integer-type-signed type)
                                  (new-arg-types (parse-alien-type '(signed 64) env))
                                  (new-arg-types (parse-alien-type '(unsigned 64) env))))
                             (t
                              (incf i (cond ((alien-double-float-type-p type)
                                             0)
                                            (t
                                             1)))
                              (new-args arg)
                              (new-arg-types type))))
                 (cond ((and (alien-integer-type-p result-type)
                             (> (sb!alien::alien-integer-type-bits result-type) 64))
                        (let ((new-result-type
                                (let ((sb!alien::*values-type-okay* t))
                                  (parse-alien-type
                                   (if (alien-integer-type-signed result-type)
                                       '(values (unsigned 64) (signed 64))
                                       '(values (unsigned 64) (unsigned 64)))
                                   env))))
                          `(lambda (function type ,@(lambda-vars))
                             (declare (ignore type))
                             (multiple-value-bind (low high)
                                 (%alien-funcall function
                                                 ',(make-alien-fun-type
                                                    :arg-types (new-arg-types)
                                                    :result-type new-result-type)
                                                 ,@(new-args))
                               (logior low (ash high 64))))))
                       (t
                        `(lambda (function type ,@(lambda-vars))
                           (declare (ignore type))
                           (%alien-funcall function
                                           ',(make-alien-fun-type
                                              :arg-types (new-arg-types)
                                              :result-type result-type)
                                           ,@(new-args))))))
        (sb!c::give-up-ir1-transform))))

;;; Callback
#-sb-xc-host
(defun alien-callback-accessor-form (type sap offset)
  (let ((parsed-type type))
    (if (alien-integer-type-p parsed-type)
        (let ((bits (sb!alien::alien-integer-type-bits parsed-type)))
               (let ((byte-offset
                      (cond ((< bits n-word-bits)
                             (- n-word-bytes
                                (ceiling bits n-byte-bits)))
                            (t 0))))
                 `(deref (sap-alien (sap+ ,sap
                                          ,(+ byte-offset offset))
                                    (* ,type)))))
        `(deref (sap-alien (sap+ ,sap ,offset) (* ,type))))))

#-sb-xc-host
(defun alien-callback-assembler-wrapper (index result-type argument-types)
  (flet ((make-tn (offset &optional (sc-name 'any-reg))
           (make-random-tn :kind :normal
                           :sc (sc-or-lose sc-name)
                           :offset offset)))
    (let* ((segment (make-segment))
           ;; How many arguments have been copied
           (arg-count 0)
           ;; How many arguments have been copied from the stack
           (stack-argument-count 0)
           (r0-tn (make-tn 0))
           (r1-tn (make-tn 1))
           (r2-tn (make-tn 2))
           (r3-tn (make-tn 3))
           (r4-tn (make-tn 4))
           (temp-tn (make-tn 5))
           (nsp-save-tn (make-tn 6))
           (gprs (list r0-tn r1-tn r2-tn r3-tn))
           (frame-size
             (loop for type in argument-types
                   sum (* n-word-bytes
                          (if (or (alien-double-float-type-p type)
                                  (and (alien-integer-type-p type)
                                       (eql (alien-type-bits type) 64)))
                              2
                              1)))))
      (setf frame-size (logandc2 (+ frame-size +number-stack-alignment-mask+)
                                 +number-stack-alignment-mask+))
      (assemble (segment)
        (emit-word segment #xe92d4ff8) ;; stmfd sp!, {r3-r11, lr}
        (inst mov-sp nsp-save-tn nsp-tn)

        ;; Make room on the stack for arguments.
        (when (plusp frame-size)
          (inst sub nsp-tn nsp-tn frame-size))
        ;; Copy arguments
        (dolist (type argument-types)
          (let ((target-tn (@ nsp-tn (* arg-count n-word-bytes)))
                ;; A TN pointing to the stack location that contains
                ;; the next argument passed on the stack.
                ;; 10 is the amount of registers saved by stmfd above.
                (stack-arg-tn (@ nsp-save-tn (* (+ 10 stack-argument-count)
                                                n-word-bytes))))
            (cond ((or (and (alien-integer-type-p type)
                            (not (eql (alien-type-bits type) 64)))
                       (alien-pointer-type-p type)
                       (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                                     type)
                       (alien-single-float-type-p type))
                   (let ((gpr (pop gprs)))
                     (cond (gpr
                            (inst str gpr target-tn))
                           (t
                            (incf stack-argument-count)
                            (inst ldr temp-tn stack-arg-tn)
                            (inst str temp-tn target-tn))))
                   (incf arg-count))
                  ((or (alien-double-float-type-p type)
                       ;; long-long
                       (alien-integer-type-p type))
                   (let ((left (length gprs)))
                     (case left
                       ((2 3 4)
                        (when (= left 3)
                          (pop gprs))
                        (inst str (pop gprs) (@ nsp-tn (* arg-count n-word-bytes)))
                        (incf arg-count)
                        (inst str (pop gprs) (@ nsp-tn (* arg-count n-word-bytes)))
                        (incf arg-count))
                       (t
                        (pop gprs)
                        ;; two-word aligned
                        (setf stack-argument-count
                              (logandc2 (+ stack-argument-count 1) 1))
                        (inst ldr temp-tn (@ nsp-save-tn (* (+ 10 stack-argument-count)
                                                            n-word-bytes)))
                        (inst str temp-tn (@ nsp-tn (* arg-count n-word-bytes)))
                        (incf arg-count)
                        (inst ldr temp-tn (@ nsp-save-tn (* (+ 11 stack-argument-count)
                                                            n-word-bytes)))
                        (inst str temp-tn (@ nsp-tn (* arg-count n-word-bytes)))
                        (incf stack-argument-count 2)
                        (incf arg-count)))))
                  (t
                   (bug "Unknown alien floating point type: ~S" type)))))
        ;; arg0 to FUNCALL3 (function)
        ;;
        ;; Indirect the access to ENTER-ALIEN-CALLBACK through
        ;; the symbol-value slot of SB-ALIEN::*ENTER-ALIEN-CALLBACK*
        ;; to ensure it'll work even if the GC moves ENTER-ALIEN-CALLBACK.
        ;; Skip any SB-THREAD TLS magic, since we don't expect anyone
        ;; to rebind the variable. -- JES, 2006-01-01
        (load-immediate-word r0-tn (+ nil-value (static-symbol-offset
                                                 'sb!alien::*enter-alien-callback*)))
        (loadw r0-tn r0-tn symbol-value-slot other-pointer-lowtag)
        ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
        (inst mov r1-tn (fixnumize index))
        ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
        (inst mov-sp r2-tn nsp-tn)
        ;; add room on stack for return value
        (inst sub nsp-tn nsp-tn 8)
        ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
        (inst mov-sp r3-tn nsp-tn)

        ;; Call
        (load-immediate-word r4-tn (foreign-symbol-address "funcall3"))
        (inst blr r4-tn)

        ;; Result now on top of stack, put it in the right register
        (cond
          ((or (and (alien-integer-type-p result-type)
                    (not (eql (alien-type-bits result-type) 64)))
               (alien-pointer-type-p result-type)
               (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                             result-type)
               (alien-single-float-type-p result-type))
           (loadw r0-tn nsp-tn))
          ((or (alien-double-float-type-p result-type)
               ;; long-long
               (alien-integer-type-p result-type))
           (loadw r0-tn nsp-tn)
           (loadw r1-tn nsp-tn 1))
          ((alien-void-type-p result-type))
          (t
           (error "Unrecognized alien type: ~A" result-type)))
        (inst mov-sp nsp-tn nsp-save-tn)
        (emit-word segment #xe8bd4ff8) ;; ldmfd sp!, {r3-r11, lr}
        (inst br lr-tn))
      (finalize-segment segment)
      ;; Now that the segment is done, convert it to a static
      ;; vector we can point foreign code to.
      (let* ((buffer (sb!assem::segment-buffer segment))
             (vector (make-static-vector (length buffer)
                                         :element-type '(unsigned-byte 8)
                                         :initial-contents buffer))
             (sap (vector-sap vector)))
        (alien-funcall
         (extern-alien "os_flush_icache"
                       (function void
                                 system-area-pointer
                                 unsigned-long))
         sap (length buffer))
        vector))))