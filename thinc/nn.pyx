cimport numpy as np
cimport cython
import numpy

from cymem.cymem cimport Pool

from .typedefs cimport weight_t

from libc.string cimport memcpy
from libc.math cimport isnan


@cython.cdivision(True)
cdef void Param_asgd(Param* self, float* grad, int t, float eta, float mu) except *:
    cdef int i
    cdef float alpha = (1 / t)
    alpha = alpha if alpha >= 0.001 else 0.001
    alpha = alpha if alpha < 0.9 else 0.9

    for i in range(self.length):
        self.step[i] = (mu * self.step[i]) - grad[i]
        self.curr[i] += (eta * self.step[i])
        if t < 1000:
            self.avg[i] = self.curr[i]
        else:
            self.avg[i] = ((1 - alpha) * self.avg[i]) + (alpha * self.curr[i])

 
cdef Param Param_init(Pool mem, int length, initializer) except *:
    cdef Param param
    param.curr = <float*>mem.alloc(length, sizeof(float))
    param.avg = <float*>mem.alloc(length, sizeof(float))
    param.step = <float*>mem.alloc(length, sizeof(float))
    param.update = Param_asgd
    param.length = length

    # Draw random values from the initializer. avg and curr should have the same
    # values. Step is initialized to 0s
    for i in range(length):
        param.curr[i] = initializer()
        param.avg[i] = param.curr[i]
    return param


cdef class EmbeddingTable:
    cdef Pool mem
    cdef Param* rows
    cdef readonly int n_rows
    cdef readonly int n_cols
    def __init__(self, n_rows, n_cols, initializer):
        n_rows += 1
        mem = Pool()
        rows = <Param*>mem.alloc(n_rows, sizeof(Param))

        cdef int i
        for i in range(n_rows):
            rows[i] = Param_init(mem, n_cols, initializer)

        self.n_rows = n_rows
        self.n_cols = n_cols
        self.mem = mem
        self.rows = rows

    @cython.boundscheck(False)
    def inc_row(self, int idx, float[:] updates):
        cdef int i
        cdef float upd
        for i, upd in enumerate(updates):
            self.rows[idx].curr[i] += upd


cdef class InputLayer:
    '''An input layer to an NN.'''
    cdef Pool mem

    cdef int length
    cdef readonly list fields
    cdef readonly list tables

    def __init__(self, input_structure, initializer):
        self.mem = Pool()
        self.length = 0
        self.tables = []
        self.indices = []
        for i, (n_rows, n_cols, fields) in enumerate(input_structure):
            self.tables.append(EmbeddingTable(n_rows, n_cols, fields, initializer))
            self.indices.append(fields)
            self.length += len(fields) * n_cols

    def __len__(self):
        return self.length
    
    @cython.boundscheck(False)
    def fill(self, float[:] output, atom_t[:] context, use_avg=False):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef const Param* param
        c = 0
        for i in range(self.tables):
            table = self.tables[i]
            for idx in self.indices[i]:
                param = &table.rows[context[idx]]
                if use_avg:
                    memcpy(&output[c], param.avg, param.length * sizeof(float))
                else:
                    memcpy(&output[c], param.curr, param.length * sizeof(float))
                c += param.length

    @cython.boundscheck(False)
    def update(self, float[:] gradient, atom_t[:] context, t, eta, mu):
        cdef int i, j, idx, c
        cdef EmbeddingTable table
        cdef Param* param
        c = 0
        for i in range(self.tables):
            table = self.tables[i]
            for idx in self.indices[i]:
                param = &table.rows[context[idx]]
                param.update(param, &gradient[c], t, eta, mu)
                c += param.length