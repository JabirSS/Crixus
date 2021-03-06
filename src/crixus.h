#ifndef CRIXUS_H
#define CRIXUS_H

#include <iostream>
#include <sstream>
#include <fstream>
#include <vector>
#include <map>
#include <list>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <cuda.h>
#include "cuda_local.cuh"
#include "ini/cpp/INIReader.h"

using namespace std;

//definitions
#define uint unsigned int
#define DATASETNAME "Compound"
#define sgn(x) (float)((x>0.)-(x<0.))
#define sqr(x) ((x)*(x))

//variables
const unsigned int           gres = 20;    // grid resolution = dr/dr_grid
const unsigned int         trimax = 50;    // maximum amount of triangles associated to one vertex particle
const unsigned int        maxlink = 500;   // maximum number of links (grid points to boundary elements & vertex particles
const unsigned int        ipoints = 17;    // number of unique integration points for gauss quadrature (without permutations)
const unsigned int max_iterations = 10000; // maximum number of iterations during complex filling

//Output structures
struct OutBuf{
  float x,y,z,nx,ny,nz,vol,surf;
  int kpar, kfluid, kent, kparmob, iref, ep1, ep2, ep3;
};

// Vertex reduction structures
// Integer index and boolean
struct intb
{
  uint idx;
  bool found;
  intb (uint a, bool b) {
    idx = a;
    found =b ;
  }
};

// 3 integers with < ordering
class mint3
{
  public:
    int x,y,z;
    bool operator<(const mint3& r) const
    {
      if (x < r.x)
        return true;
      else if (x == r.x) {
        if (y < r.y)
          return true;
        else if (y == r.y) {
          if (z < r.z)
            return true;
        }
      }
      return false;
    }
    mint3(int a, int b, int c) {
      x = a;
      y = b;
      z = c;
    }
    mint3() { mint3(0,0,0); }
};


//function headers
int hdf5_output (OutBuf *buf, int len, const char *filename);

int vtk_output (OutBuf *buf, int len, const char *filename);

// wrapper for writer functions
int generic_output(OutBuf *buf, int start, int nelem, const char* outname_c, int opt);

inline void scalar_array(FILE *fid, const char *type, const char *name, size_t offset);

inline void vector_array(FILE *fid, const char *type, const char *name, uint dim, size_t offset);

inline void vector_array(FILE *fid, const char *type, uint dim, size_t offset);

int crixus_main(int, char**);

void find_in_cell(list<intb>::iterator il_neib, list<intb>::iterator il_end, const float xi, const float yi, const float zi, vector<uint>& new_ids_map, vector<vector<float> >& all_verts, const float dx, const uint new_id);

void offset_find_in_cell(int x, int y, int z, mint3 key, map<mint3, list<intb> >cell_map, list<intb>::iterator il_neib, list<intb>::iterator il_end, const float xi, const float yi, const float zi, vector<uint>& new_ids_map, vector<vector<float> >& all_verts, const float dx, const uint new_id);

void remove_duplicate_vertices(vector<vector<float> >& all_verts, vector<vector<uint> >& old_ids, vector<vector<float> >& new_verts, vector<vector<uint> >& new_ids, const float dx);

/* Endianness check: (char*)&endian_int reads the first byte of the int,
 * which is 0 on big-endian machines, and 1 in little-endian machines */
static int endian_int=1;
static const char* endianness[2] = { "BigEndian", "LittleEndian" };

//debug
//#define bdebug 2344-960

#endif
