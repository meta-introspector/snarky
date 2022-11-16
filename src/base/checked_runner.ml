open Core_kernel
module Constraint0 = Constraint

let stack_to_string = Ast_runner.stack_to_string

let eval_constraints = ref true

let eval_constraints_ref = eval_constraints

module Make_checked
    (Backend : Backend_extended.S)
    (As_prover : As_prover_intf.S with type 'f field := Backend.Field.t) =
struct
  type run_state = Backend.Field.t Run_state.t

  module Types = struct
    module Checked = struct
      type ('a, 'f) t = run_state -> run_state * 'a
    end

    module As_prover = struct
      type ('a, 'f) t = ('a, 'f) As_prover.t
    end

    module Typ = struct
      include Types.Typ.T

      type ('var, 'value, 'f) t = ('var, 'value, 'f, (unit, 'f) Checked.t) typ
    end

    module Provider = struct
      include Types.Provider.T

      type ('a, 'f) t =
        (('a Request.t, 'f) As_prover.t, ('a, 'f) As_prover.t) provider
    end
  end

  type 'f field = Backend.Field.t

  type ('a, 'f) t = ('a, 'f field) Types.Checked.t

  include Monad_let.Make2 (struct
    type ('a, 'f) t = ('a, 'f field) Types.Checked.t

    let return x s = (s, x)

    let map =
      `Custom
        (fun x ~f s ->
          let s, a = x s in
          (s, f a) )

    let bind x ~f s =
      let s, a = x s in
      f a s
  end)

  open Constraint
  open Backend
  open Checked_ast

  let get_value (t : Field.t Run_state.t) : Cvar.t -> Field.t =
    let get_one i = Run_state.get_variable_value t i in
    Cvar.eval (`Return_values_will_be_mutated get_one)

  let run_as_prover x state =
    match (x, Run_state.has_witness state) with
    | Some x, true ->
        let old = Run_state.as_prover state in
        Run_state.set_as_prover state true ;
        let y = As_prover.run x (get_value state) in
        Run_state.set_as_prover state old ;
        (state, Some y)
    | _, _ ->
        (state, None)

  let as_prover x s =
    let s', (_ : unit option) = run_as_prover (Some x) s in
    (s', ())

  let mk_lazy x s =
    let old_stack = Run_state.stack s in
    ( s
    , Lazy.from_fun (fun () ->
          let stack = Run_state.stack s in

          (* Add a label to indicate that the new stack is the point at which
             this was forced. When printed for errors, this will split the
             stack into

             ...
             stack to lazy
             ...

             Lazy value forced at:
             ...
             stack to lazy forcing point
             ...
          *)
          let label = "\nLazy value forced at:" in
          let _s', y =
            x () (Run_state.set_stack s (old_stack @ (label :: stack)))
          in
          y ) )

  let with_label lab t s =
    let stack = Run_state.stack s in
    Option.iter (Run_state.log_constraint s) ~f:(fun f ->
        f ~at_label_boundary:(`Start, lab) None ) ;
    let s', y = t () (Run_state.set_stack s (lab :: stack)) in
    Option.iter (Run_state.log_constraint s) ~f:(fun f ->
        f ~at_label_boundary:(`End, lab) None ) ;
    (Run_state.set_stack s' stack, y)

  let log_constraint { basic; _ } s =
    match basic with
    | Boolean var ->
        Format.(asprintf "Boolean %s" (Field.to_string (get_value s var)))
    | Equal (var1, var2) ->
        Format.(
          asprintf "Equal %s %s"
            (Field.to_string (get_value s var1))
            (Field.to_string (get_value s var2)))
    | Square (var1, var2) ->
        Format.(
          asprintf "Square %s %s"
            (Field.to_string (get_value s var1))
            (Field.to_string (get_value s var2)))
    | R1CS (var1, var2, var3) ->
        Format.(
          asprintf "R1CS %s %s %s"
            (Field.to_string (get_value s var1))
            (Field.to_string (get_value s var2))
            (Field.to_string (get_value s var3)))
    | _ ->
        Format.asprintf
          !"%{sexp:(Field.t, Field.t) Constraint0.basic}"
          (Constraint0.Basic.map basic ~f:(get_value s))

  let add_constraint ~stack ({ basic; annotation } : Constraint.t)
      (Constraint_system.T ((module C), system) : Field.t Constraint_system.t) =
    let label = Option.value annotation ~default:"<unknown>" in
    C.add_constraint system basic ~label:(stack_to_string (label :: stack))

  let add_constraint c s =
    if Run_state.as_prover s then
      (* Don't add constraints as the prover, or the constraint system won't match! *)
      (s, ())
    else (
      Option.iter (Run_state.log_constraint s) ~f:(fun f -> f (Some c)) ;
      if Run_state.eval_constraints s && not (Constraint.eval c (get_value s))
      then
        failwithf
          "Constraint unsatisfied (unreduced):\n\
           %s\n\
           %s\n\n\
           Constraint:\n\
           %s\n\
           Data:\n\
           %s"
          (Constraint.annotation c)
          (stack_to_string (Run_state.stack s))
          (Sexp.to_string (Constraint.sexp_of_t c))
          (log_constraint c s) () ;
      if not (Run_state.as_prover s) then
        Option.iter (Run_state.system s) ~f:(fun system ->
            add_constraint ~stack:(Run_state.stack s) c system ) ;
      (s, ()) )

  let with_handler h t s =
    let handler = Run_state.handler s in
    let s', y =
      t () (Run_state.set_handler s (Request.Handler.push handler h))
    in
    (Run_state.set_handler s' handler, y)

  let exists
      (Types.Typ.Typ
        { Types.Typ.var_of_fields
        ; value_to_fields
        ; size_in_field_elements
        ; check
        ; constraint_system_auxiliary
        ; _
        } ) p s =
    if Run_state.has_witness s then (
      let old = Run_state.as_prover s in
      Run_state.set_as_prover s true ;
      let value =
        As_prover.Provider.run p (Run_state.stack s) (get_value s)
          (Run_state.handler s)
      in
      Run_state.set_as_prover s old ;
      let var =
        let store_value =
          if Run_state.as_prover s then
            (* If we're nested in a prover block, create constants instead of
               storing.
            *)
            Cvar.constant
          else Run_state.store_field_elt s
        in
        let fields, aux = value_to_fields value in
        let field_vars = Array.map ~f:store_value fields in
        var_of_fields (field_vars, aux)
      in
      (* TODO: Push a label onto the stack here *)
      let s, () = check var s in
      (s, { Handle.var; value = Some value }) )
    else
      let var =
        var_of_fields
          ( Array.init size_in_field_elements ~f:(fun _ ->
                Run_state.alloc_var s () )
          , constraint_system_auxiliary () )
      in
      (* TODO: Push a label onto the stack here *)
      let s, () = check var s in
      (s, { Handle.var; value = None })

  let next_auxiliary () s = (s, Run_state.next_auxiliary s)

  let direct f = f

  let constraint_count ?(weight = Fn.const 1)
      ?(log = fun ?start:_ _lab _pos -> ()) t =
    (* TODO: Integrate log with log_constraint *)
    let count = ref 0 in
    let log_constraint ?at_label_boundary c =
      ( match at_label_boundary with
      | None ->
          ()
      | Some (pos, lab) ->
          let start = match pos with `Start -> true | _ -> false in
          log ~start lab !count ) ;
      count := !count + Option.value_map ~default:0 ~f:weight c
    in
    let state =
      Run_state.make ~num_inputs:0 ~input:Run_state.Vector.null
        ~next_auxiliary:(ref 1) ~aux:Run_state.Vector.null
        ~eval_constraints:false ~log_constraint ~with_witness:false ()
    in
    let _ = t () state in
    !count
end

module type Run_extras = sig
  type field

  type cvar

  module Types : Types.Types

  val get_value : field Run_state.t -> cvar -> field

  val run_as_prover :
       ('a, field) Types.As_prover.t option
    -> field Run_state.t
    -> field Run_state.t * 'a option
end

module Make (Backend : Backend_extended.S) = struct
  open Backend

  type 'f field = 'f

  let constraint_logger = ref None

  let set_constraint_logger f = constraint_logger := Some f

  let clear_constraint_logger () = constraint_logger := None

  module Checked_runner = Make_checked (Backend) (As_prover)

  type run_state = Checked_runner.run_state

  type state = run_state

  type ('a, 't) run = 't -> run_state -> run_state * 'a

  include (
    Checked_runner :
      sig
        include
          Checked_intf.Basic
            with module Types := Checked_runner.Types
            with type 'f field := 'f Checked_runner.field

        include
          Run_extras
            with module Types := Checked_runner.Types
            with type field := Backend.Field.t
             and type cvar := Backend.Cvar.t
      end )

  module Types = Checked_ast.Types
  include Ast_runner.Make_runner (Checked_runner)

  let run f x = f x

  let dummy_vector = Run_state.Vector.null

  let fake_state next_auxiliary stack =
    Run_state.make ~num_inputs:0 ~input:Run_state.Vector.null ~next_auxiliary
      ~aux:Run_state.Vector.null ~eval_constraints:false ~stack
      ~with_witness:false ()

  module State = struct
    let make ~num_inputs ~input ~next_auxiliary ~aux ?system
        ?(eval_constraints = !eval_constraints_ref) ?handler ~with_witness
        ?log_constraint () =
      let log_constraint =
        match log_constraint with
        | Some _ ->
            log_constraint
        | None ->
            !constraint_logger
      in
      (* We can't evaluate the constraints if we are not computing over a value. *)
      let eval_constraints = eval_constraints && with_witness in
      Option.iter
        (system : R1CS_constraint_system.t option)
        ~f:(fun system ->
          R1CS_constraint_system.set_primary_input_size system num_inputs ) ;
      let system =
        Option.map system ~f:(fun sys ->
            let module M = struct
              module Field = struct
                type nonrec t = Field.t
              end

              include R1CS_constraint_system
            end in
            Constraint_system.T ((module M), sys) )
      in
      Run_state.make ~num_inputs ~input ~next_auxiliary ~aux ?system
        ~eval_constraints ?log_constraint ?handler ~with_witness ()
  end
end

module type S = sig
  include Run_extras

  type constr

  type r1cs

  val set_constraint_logger :
    (?at_label_boundary:[ `Start | `End ] * string -> constr -> unit) -> unit

  val clear_constraint_logger : unit -> unit

  type run_state = field Run_state.t

  type state = run_state

  type ('a, 't) run = 't -> run_state -> run_state * 'a

  val run : ('a, field) Types.Checked.t -> run_state -> run_state * 'a

  module State : sig
    val make :
         num_inputs:int
      -> input:field Run_state.Vector.t
      -> next_auxiliary:int ref
      -> aux:field Run_state.Vector.t
      -> ?system:r1cs
      -> ?eval_constraints:bool
      -> ?handler:Request.Handler.t
      -> with_witness:bool
      -> ?log_constraint:
           (   ?at_label_boundary:[ `End | `Start ] * string
            -> (field Cvar.t, field) Constraint.t option
            -> unit )
      -> unit
      -> field Run_state.t
  end
end
