#' @include utils-data.R
NULL

nn_Module <- R6::R6Class(
  classname = "nn_Module",
  lock_objects = FALSE,
  public = list(
    training = TRUE,
    
    forward = function(...) {
      not_implemented_error("Forward method is not implemented")
    },
    
    add_module = function(name, module) {
      
      if (is.numeric(name))
        name <- as.character(name)
      
      private$modules_[[name]] <- module
    },
    
    register_parameter = function(name, param) {
      private$parameters_[[name]] <- param
    },
    
    register_buffer = function(name, tensor, persistent = TRUE) {
      private$buffers_[[name]] <- tensor
      
      if (persistent) {
        private$non_persistent_buffers_ <- private$non_persistent_buffers_[
          private$non_persistent_buffers_ != name
        ]
      } else {
        private$non_persistent_buffers <- unique(c(
          private$non_persistent_buffers_,
          name
        ))
      }
      
    },
    
    train = function(mode = TRUE) {
      self$training <- mode
      lapply(private$modules_, function(m) m$train(mode))
      invisible(self)
    },
    
    eval = function() {
      self$train(FALSE)
    },
    
    .apply = function(fn) {
      
      for (module in private$modules_) {
        module$.apply(fn)
      }
      
      for (param_name in names(private$parameters_)) {
        param <- private$parameters_[[param_name]]
        
        if (!is.null(param)) {
          # Tensors stored in modules are graph leaves, and we don't want to
          # track autograd history of `param_applied`, so we have to use
          # `with torch.no_grad():`
          with_no_grad({
            param_applied <- fn(param)
          })
          private$parameters_[[param_name]] <- nn_parameter(param_applied)
        }
        
        if (!is_undefined_tensor(param$grad)) {
          with_no_grad({
            grad_applied <- fn(param$grad)
          })
          grad_applied$requires_grad_(param$grad$requires_grad)
          private$parameters_[[param_name]]$set_grad_(grad_applied)
        }
        
      }
      
      for (buf_name in names(private$buffers_)) {
        buf <- private$buffers_[[buf_name]]
        if (!is.null(buf)) {
          private$buffers_[[buf_name]] <- fn(buf)
        }
      }
      
      invisible(create_nn_module_callable(self))
    },
    cuda = function(device = NULL) {
      self$.apply(function(x) x$cuda())
    },
    cpu = function() {
      self$.apply(function(x) x$cpu())
    },
    to = function(dtype = NULL, device = NULL, tensor = NULL, non_blocking = FALSE, copy = FALSE, 
                  memory_format = torch_preserve_format()) {
      
      if (!is.null(dtype)) {
        if (!dtype$is_floating_point)
          value_error("nn.Module.to only accepts floating point '
                      'dtypes, but got desired dtype {dtype}")
      }

      self$.apply(function(x) {
        if (x$is_floating_point())
          x$to(dtype, device, tensor, non_blocking, copy, memory_format)
        else
          x$to(device = device, non_blocking = non_blocking, copy = copy, 
               memory_format = memory_format)
      })
    },
    
    .save_to_state_dict = function(prefix, keepvars) {
      
      out <- list()
      
      for (param_name in names(private$parameters_)) {
        param <- private$parameters_[[param_name]]
        if (!is.null(param)) {
          
          if (!keepvars)
            param$detach
          out[[paste0(prefix, param_name)]] <- param
        }
      }
      
      for (buf_name in names(private$buffers_)) {
        buf <- private$buffers_[[buf_name]]
        if (!is.null(buf) && !buf_name %in% private$non_persistent_buffers_) {
          if (!keepvars)
            buf$detach()
          out[[paste0(prefix, buf_name)]] <- buf
        }
      }
      
      out
    },
    
    state_dict = function(prefix = "", keepvars = FALSE) {
      
      out <- list()
      out <- c(out, self$.save_to_state_dict(prefix, keepvars))
      
      for (module_name in names(private$modules_)) {
        module <- private$modules_[[module_name]]
        if (!is.null(module)) {
          out <- c(out, module$state_dict(prefix = paste0(prefix, module_name, "."), 
                            keepvars = keepvars))
        }
      }
      
      out
    },
    
    .load_from_state_dict = function(state_dict, prefix){
      
      persistent_buffers <- private$buffers_[!names(private$buffers_) %in% private$non_persistent_buffers_]
      local_name_params <- c(private$parameters_, persistent_buffers)
      local_state <- local_name_params[!sapply(local_name_params, is.null)]
      
      for (name in names(local_state)) {
        key <- paste0(prefix, name)
        if (key %in% names(state_dict)) {
         input_param <- state_dict[[key]] 
         param <- local_state[[name]]
         with_no_grad({
           param$copy_(input_param)
         })
        } else {
          value_error("Could not find {key} in the state_dict.")
        }
      }
      
    },
    
    load_state_dict = function(state_dict) {
      
      load <- function(module, state_dict, prefix="") {
        module$.load_from_state_dict(state_dict, prefix)
        for (nm in names(module$.__enclos_env__$private$modules_)) {
         child <- module$.__enclos_env__$private$modules_[[nm]]
         if (!is.null(child)) {
           load(child, state_dict, prefix = paste0(prefix, nm, "."))
         }
        }
      }
      
      load(self, state_dict)
      
      invisible(create_nn_module_callable(self))
    },
    zero_grad = function() {
      for (p in self$parameters) {
        if (!is_undefined_tensor(p$grad)) {
          p$grad$detach_()
          p$grad$zero_()
        }
      }
    },
    
    apply = function(fn) {
      for (module in private$modules_) {
        module$apply(fn)
      }
      fn(self)
      invisible(create_nn_module_callable(self))
    }
    
  ),
  private = list(
    parameters_ = list(),
    buffers_ = list(),
    modules_ = list(),
    non_persistent_buffers_ = character()
  ),
  active = list(
    parameters = function() {
      pars <- lapply(private$modules_, function(x) x$parameters)
      pars <- append(pars, private$parameters_)
      pars <- unlist(pars, recursive = TRUE, use.names = TRUE)
      
      # deduplicate the parameters based on the storage location
      # see (#305)
      # in python a `set` is used to do this. but there's no straightforward
      # way to do this in R because the R objects could be possibly different
      # and still point to the same parameter in memory.
      addresses <- sapply(pars, function(x) x$storage()$data_ptr())
      pars <- pars[!duplicated(addresses)]
      
      pars
    }
  )
)

#' Creates an `nn_parameter`
#' 
#' Indicates to nn_module that `x` is a parameter
#' 
#' @param x the tensor that you want to indicate as parameter
#' @param requires_grad whether this parameter should  have 
#'   `requires_grad = TRUE`
#' 
#' @export
nn_parameter <- function(x, requires_grad = TRUE) {
  if (!is_torch_tensor(x))
    stop("`x` must be a tensor.")
  x$requires_grad_(requires_grad)
  class(x) <- c(class(x), "nn_parameter")
  x
}

#' Checks if an object is a nn_parameter
#' 
#' @param x the object to check
#'
#' @export
is_nn_parameter <- function(x) {
  inherits(x, "nn_parameter")
}

#' Creates a nn_buffer
#' 
#' Indicates that a tensor is a buffer in a nn_module
#'
#' @param x the tensor that will be converted to nn_buffer
#' @param persistent whether the buffer should be persistent or not.
#' 
#' @export
nn_buffer <- function(x, persistent = TRUE) {
  class(x) <- c(class(x), "nn_buffer")
  attr(x, "persistent") <- persistent
  x
}

#' Checks if the object is a nn_buffer
#' 
#' @param x object to check
#'
#' @export
is_nn_buffer <- function(x) {
  inherits(x, "nn_buffer")
}

#' Checks if the object is an nn_module
#'
#' @param x object to check
#'
#' @export
is_nn_module <- function(x) {
  inherits(x, "nn_module") && !inherits(x, "nn_module_generator")
}

#' Base class for all neural network modules.
#' 
#' Your models should also subclass this class.
#' 
#' Modules can also contain other Modules, allowing to nest them in a tree 
#' structure. You can assign the submodules as regular attributes.
#' 
#' @param classname an optional name for the module
#' @param inherit an optional module to inherit from
#' @param ... methods implementation 
#' @param private passed to [R6::R6Class()].
#' @param active passed to [R6::R6Class()].
#' @param parent_env passed to [R6::R6Class()].
#' 
#' @examples 
#' model <- nn_module(
#'  initialize = function() {
#'    self$conv1 <- nn_conv2d(1, 20, 5)
#'    self$conv2 <- nn_conv2d(20, 20, 5)
#'  },
#'  forward = function(input) {
#'    input <- self$conv1(input)
#'    input <- nnf_relu(input)
#'    input <- self$conv2(input)
#'    input <- nnf_relu(input)
#'    input
#'  }
#' )
#' 
#' @export
nn_module <- function(classname = NULL, inherit = nn_Module, ..., 
                      private = NULL, active = NULL,
                      parent_env = parent.frame()) {
  
  if (inherits(inherit, "nn_module"))
    inherit <- attr(inherit, "module")
  
  e <- new.env(parent = parent_env)
  e$inherit <- inherit
    
  classes <- c(classname, "nn_module")
  
  Module <- R6::R6Class(
    classname = classname,
    inherit = inherit,
    lock_objects = FALSE,
    public = list(
      .classes = classes,
      ...
    ),
    private = private,
    active = active,
    parent_env = e
  )
  
  init <- get_init(Module)
  
  fun <- rlang::new_function(
    args = rlang::fn_fmls(init), 
    body = rlang::expr({
      instance <- Module$new(!!!rlang::fn_fmls_syms(init))
      create_nn_module_callable(instance)
    })
  )
  attr(fun, "class") <- c(classes, "nn_module_generator")
  attr(fun, "module") <- Module
  fun
}

create_nn_module_callable <- function(instance) {
  f <- instance$forward
  
  attr(f, "class") <- instance$.classes
  attr(f, "module") <- instance
  f
}

#' @export
`$.nn_module` <- function(x, y) {
  module <- attr(x, "module")
  do.call("$", args = list(module, y))
}

#'@export
`[[.nn_module` <- function(x, y) {
  module <- attr(x, "module")
  do.call("[[", args = list(module, y))
}

#' @export
`$.nn_Module` <- function(x, y) {
  x[[y]]
}

#' @export
`[[.nn_Module` <- function(x, y) {
  
  if (y == ".__enclos_env__")
    return(NextMethod())
  
  if (is.numeric(y))
    return(x[[".__enclos_env__"]][["private"]][["modules_"]][[y]])
  
  pars <- x[[".__enclos_env__"]][["private"]][["parameters_"]]
  if (!is.null(pars)) {
    o <- pars[[y]]
    if (!is.null(o))
      return(o)
  }
  
  bufs <- x[[".__enclos_env__"]][["private"]][["buffers_"]]
  if (!is.null(bufs)) {
    o <- bufs[[y]]
    if (!is.null(o))
      return(o)
  }
  
  mods <- x[[".__enclos_env__"]][["private"]][["modules_"]]
  if (!is.null(mods)) {
    o <- mods[[y]]
    if (!is.null(o))
      return(o)
  }
  
  NextMethod("[[", x)
}

#' @export
`[[<-.nn_Module` <- function(x, name, value) {

  if (inherits(value, "nn_parameter")) {
    x$register_parameter(name, value)
  } else if (inherits(value, "nn_buffer")) {
    x$register_buffer(name, value, attr(value, "persistent"))
  } else if (is_nn_module(value)) {
    x$add_module(name, value)
  } else {
    NextMethod("$<-", x)
  }
  
  invisible(x)
}

#' @export
`$<-.nn_Module` <- function(x, name, value) {
  x[[name]] <- value
  invisible(x)
}

#' @export
`$<-.nn_module` <- function(x, name, value) {
  attr(x, "module")[[name]] <- value
  invisible(x)
}

#' @export
`[[<-.nn_module` <- `$<-.nn_module`

#' @export
names.nn_module <- function(x, ...) {
  x <- attr(x, "module")
  NextMethod("names", x)
}

#' @export
print.nn_module <- function(x, ...) {
  x <- attr(x, "module")
  print(x)
}

#' A sequential container
#' 
#' A sequential container.
#' Modules will be added to it in the order they are passed in the constructor.
#' See examples.
#' 
#' @param ... sequence of modules to be added
#' @param name optional name for the generated module.
#' 
#' @examples 
#' 
#' model <- nn_sequential(
#'   nn_conv2d(1, 20, 5),
#'   nn_relu(),
#'   nn_conv2d(20, 64, 5),
#'   nn_relu()
#' )
#' input <- torch_randn(32, 1, 28, 28)
#' output <- model(input)
#' 
#' @export
nn_sequential <- function(... , name = NULL) {
  module <- nn_module(
    classname = ifelse(is.null(name), "nn_sequential", name),
    initialize = function(...) {
      modules <- rlang::list2(...)
      for (i in seq_along(modules)) {
        self$add_module(name = i - 1, module = modules[[i]])  
      }
    },
    forward = function(input) {
      for (module in private$modules_) {
        input <- module(input)
      }
      input
    }
  )
  module(...)
}

#' Holds submodules in a list.
#' 
#' [nn_module_list] can be indexed like a regular R list, but
#' modules it contains are properly registered, and will be visible by all
#' `nn_module` methods.
#' 
#' @param modules a list of modules to add
#' 
#' @examples
#' 
#' my_module <- nn_module(
#'  initialize = function() {
#'    self$linears <- nn_module_list(lapply(1:10, function(x) nn_linear(10, 10)))
#'  },
#'  forward = function(x) {
#'   for (i in 1:length(self$linears))
#'     x <- self$linears[[i]](x)
#'   x
#'  }
#' )
#'
#' @export
nn_module_list <- nn_module(
  "nn_module_list",
  initialize = function(modules = list()) {
    for (i in seq_along(modules))
      self$add_module(i - 1, modules[[i]])
  },
  insert = function(index, module) {
    modules <- append(private$modules_, list(module), after = index - 1)
    private$modules_ <- NULL
    for (i in seq_along(modules)) {
      self$add_module(i - 1, modules[[i]])
    }
  },
  append = function(module) {
    i <- length(private$modules_)
    self$add_module(i, module)
  },
  extend  = function(modules) {
    for (j in seq_along(modules)) {
      self$append(modules[[j]])
    }
  }
)

#' @export
`[[.nn_module_list` <- function(x, y) {
  if (rlang::is_scalar_integerish(y))
    x$.__enclos_env__$private$modules_[[y]]
  else
    NextMethod("[[")
}

#' @export
length.nn_module_list <- function(x, ...) {
  length(x$.__enclos_env__$private$modules_)
}